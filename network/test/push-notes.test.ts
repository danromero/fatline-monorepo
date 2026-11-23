import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { beforeEach, describe, test } from "node:test";
import { fromHex } from "../src/protocol/protobuf.ts";
import { collapseFor, hourOf, MAX_NOTE_BYTES, noteBytes, open, seal } from "../src/protocol/push.ts";
import type { Note } from "../src/protocol/push.ts";
import { MIGRATIONS } from "../src/server/migrations.ts";
import { PUSH_SQL } from "../src/server/pushsql.ts";
import { lastSlot, nextSlot } from "../src/server/slots.ts";

/**
 * Notification notes on their own: sealing against the shared test vectors, how big a note can get,
 * the collapse value, the statements that pick who hears a new post and who's due a twice-a-day
 * summary, on the real migrations in SQLite, and when summaries go.
 */

interface Vector {
  name: string;
  key: string;
  nonce: string;
  plaintext: string;
  sealed: string;
}

const { vectors } = JSON.parse(readFileSync(new URL("./push-vectors.json", import.meta.url), "utf8")) as { vectors: Vector[] };
const utf8 = (text: string) => new TextEncoder().encode(text);
const text = (bytes: Uint8Array | null) => (bytes ? new TextDecoder().decode(bytes) : null);

describe("sealing", () => {
  test("seals each test vector to its sealed value, and opens it again", async () => {
    assert.ok(vectors.length >= 5);
    for (const vector of vectors) {
      const key = fromHex(vector.key)!;
      assert.equal(await seal(key, utf8(vector.plaintext), fromHex(vector.nonce)!), vector.sealed, vector.name);
      assert.equal(text(await open(key, vector.sealed)), vector.plaintext, vector.name);
    }
  });

  test("the notes among them are byte for byte what the server writes", () => {
    for (const vector of vectors.filter((item) => item.plaintext.startsWith("{"))) {
      assert.equal(text(noteBytes(JSON.parse(vector.plaintext) as Note)), vector.plaintext, vector.name);
    }
  });

  test("a wrong key, a changed byte, or a short note opens to nothing", async () => {
    const [, , reply] = vectors;
    const key = fromHex(reply!.key)!;
    const other = Uint8Array.from(key, (byte) => byte ^ 1);
    assert.equal(await open(other, reply!.sealed), null);
    const changed = reply!.sealed.slice(0, 20) + (reply!.sealed[20] === "A" ? "B" : "A") + reply!.sealed.slice(21);
    assert.equal(await open(key, changed), null);
    assert.equal(await open(key, "AAAA"), null);
    assert.equal(await open(key, "not base64url!"), null);
  });

  test("each seal takes a new nonce", async () => {
    const key = crypto.getRandomValues(new Uint8Array(32));
    const [a, b] = [await seal(key, utf8("same")), await seal(key, utf8("same"))];
    assert.notEqual(a, b);
    assert.equal(text(await open(key, a)), "same");
  });
});

describe("a note's size", () => {
  const note = (body: string): Note => ({
    v: 1, kind: "post", fid: 1234567890123456, username: "a-long-username1", text: body, pictures: 2,
    post: "0x" + "ab".repeat(20), thread: "0x" + "ab".repeat(20), count: 999, usernames: ["a-long-username1", "a-long-username2", "!1234567890123456"],
  });

  test("text over 280 characters is cut to 280, ending in an ellipsis", () => {
    const opened = JSON.parse(text(noteBytes(note("é".repeat(300))))!) as Note;
    assert.equal(opened.text, "é".repeat(279) + "…");
    assert.equal(text(noteBytes(note("é".repeat(280)))), JSON.stringify(note("é".repeat(280))), "280 is kept whole");
  });

  test("text that would make the note too big is cut by whole characters, so sealed stays under 3 KB", async () => {
    const family = "👨‍👩‍👧‍👦";
    for (const body of [family.repeat(280), "\u0001".repeat(280), `"`.repeat(280)]) {
      const bytes = noteBytes(note(body));
      assert.ok(bytes.length <= MAX_NOTE_BYTES, `${bytes.length} bytes`);
      const opened = JSON.parse(text(bytes)!) as Note;
      assert.ok(body.startsWith(opened.text.replace(/…$/, "")), "a prefix of the post");
      const sealed = await seal(crypto.getRandomValues(new Uint8Array(32)), bytes);
      assert.ok(sealed.length < 3072, `sealed is ${sealed.length} characters`);
    }
    assert.ok((JSON.parse(text(noteBytes(note(family.repeat(280))))!) as Note).text.endsWith(`${family}…`));
  });
});

describe("collapse", () => {
  test("is the same all hour for a handle, and changes with the hour and the handle", async () => {
    const hour = hourOf(Date.UTC(2026, 10, 19, 14, 0, 0) / 1000);
    assert.equal(hourOf(Date.UTC(2026, 10, 19, 14, 59, 59) / 1000), hour);
    const value = await collapseFor("handle-0001", hour);
    assert.match(value, /^[A-Za-z0-9_-]{43}$/);
    assert.equal(await collapseFor("handle-0001", hour), value);
    assert.notEqual(await collapseFor("handle-0001", hour + 1), value);
    assert.notEqual(await collapseFor("handle-0002", hour), value);
  });

  test("for summaries, is fixed per handle, and differs from every hour's", async () => {
    const value = await collapseFor("handle-0001", "digest");
    assert.match(value, /^[A-Za-z0-9_-]{43}$/);
    assert.equal(await collapseFor("handle-0001", "digest"), value);
    assert.notEqual(await collapseFor("handle-0002", "digest"), value);
    assert.notEqual(await collapseFor("handle-0001", hourOf(Date.now() / 1000)), value);
  });
});

describe("when summaries go", () => {
  const at = (iso: string) => Date.parse(iso) / 1000;
  const iso = (seconds: number) => new Date(seconds * 1000).toISOString().replace(".000", "");

  test("9 and 21 o'clock in UTC", () => {
    assert.equal(iso(lastSlot("UTC", at("2026-11-20T12:00:00Z"))), "2026-11-20T09:00:00Z");
    assert.equal(iso(lastSlot("UTC", at("2026-11-20T09:00:00Z"))), "2026-11-20T09:00:00Z", "a slot is its own latest");
    assert.equal(iso(nextSlot("UTC", at("2026-11-20T09:00:00Z"))), "2026-11-20T21:00:00Z", "the next is after it");
    assert.equal(iso(lastSlot("UTC", at("2026-11-20T08:59:59Z"))), "2026-11-19T21:00:00Z");
  });

  test("by the local clock, across summer time's start and end", () => {
    // New York left summer time at 2 a.m. on November 1, 2026: 13 hours from 9 p.m. to 9 a.m.
    assert.equal(iso(lastSlot("America/New_York", at("2026-11-01T12:00:00Z"))), "2026-11-01T01:00:00Z");
    assert.equal(iso(nextSlot("America/New_York", at("2026-11-01T12:00:00Z"))), "2026-11-01T14:00:00Z");
    // And started it on March 8, 2026: 11 hours.
    assert.equal(iso(lastSlot("America/New_York", at("2026-03-08T12:00:00Z"))), "2026-03-08T02:00:00Z");
    assert.equal(iso(nextSlot("America/New_York", at("2026-03-08T12:00:00Z"))), "2026-03-08T13:00:00Z");
  });

  test("in zones a half or three quarters of an hour off", () => {
    assert.equal(iso(nextSlot("Asia/Kolkata", at("2026-11-20T00:00:00Z"))), "2026-11-20T03:30:00Z");
    assert.equal(iso(nextSlot("Asia/Kathmandu", at("2026-11-20T00:00:00Z"))), "2026-11-20T03:15:00Z");
    assert.equal(iso(lastSlot("Pacific/Chatham", at("2026-11-20T12:00:00Z"))), "2026-11-20T07:15:00Z");
  });
});

describe("who's due a summary", () => {
  let db: DatabaseSync;
  const run = (sql: string, ...values: (string | number | null)[]) => db.prepare(sql).run(...values);
  let posted = 0;
  /** A post by `fid` at `time`, a reply when it has a parent. */
  const post = (fid: number, time: number, parent: string | null = null) => {
    const hash = `0x${String(++posted).padStart(40, "0")}`;
    run("INSERT INTO posts (hash, fid, time, parent, text, mentions, embeds, received) VALUES (?, ?, ?, ?, 'hi', '[]', '[]', ?)", hash, fid, time, parent, time);
    return hash;
  };

  /** Members 1 to 4, each with a live key and a device set to twice a day, added at 100: 1 to 3 in UTC, 4 in Kolkata. */
  beforeEach(() => {
    db = new DatabaseSync(":memory:");
    for (const sql of MIGRATIONS.flat()) db.exec(sql);
    for (const fid of [1, 2, 3, 4]) {
      run("INSERT INTO members (fid, custody, joined, checked) VALUES (?, '0x', 1, 1)", fid);
      run("INSERT INTO network_keys (key, fid, device_key, issued, signature, added) VALUES (?, ?, 'd', 1, 's', 1)", `k${fid}`, fid);
      run("INSERT INTO push_targets (network_key, fid, relay, handle, key, added, level, tz, digest_slot) VALUES (?, ?, 'r', ?, 'x', 100, 'digest', ?, 100)",
        `k${fid}`, fid, `h${fid}`, fid === 4 ? "Asia/Kolkata" : "UTC");
    }
  });

  interface Row { fid: number; slot: number; count: number; newest: number | null; post: string | null; fids: string }
  /** Who's due with UTC's slot at `utc` and Kolkata's at `kolkata`, by FID. */
  const due = (utc: number, kolkata = 0, most = 100) => {
    const rows = db.prepare(PUSH_SQL.digests).all(JSON.stringify([["UTC", utc], ["Asia/Kolkata", kolkata]]), most) as unknown as Row[];
    return new Map(rows.map((row) => [row.fid, { slot: row.slot, count: row.count, newest: row.newest, post: row.post, authors: JSON.parse(row.fids) as number[] }]));
  };

  test("devices in a zone whose slot came since they were last due, with what they haven't read", () => {
    post(2, 50);
    const first = post(2, 150);
    post(1, 160, first);
    const last = post(3, 170);
    post(3, 180, first);
    const rows = due(200);
    assert.deepEqual([...rows.keys()].sort(), [1, 2, 3], "not 4, whose Kolkata slot hasn't come");
    assert.deepEqual(rows.get(1), { slot: 200, count: 2, newest: 170, post: last, authors: [3, 2] }, "posts since it was added, not replies");
    assert.deepEqual(rows.get(2)!.authors, [3], "not its own");
    assert.equal(due(100).size, 0, "a slot no later than the last it was due at");
    assert.deepEqual([...due(0, 200).keys()], [4]);
  });

  test("from the member's seen, without muted or deleted posts", () => {
    post(2, 150);
    const kept = post(3, 170);
    const muted = post(4, 175);
    const deleted = post(2, 180);
    run("UPDATE posts SET deleted = 1 WHERE hash = ?", deleted);
    run("INSERT INTO mutes (fid, muted) VALUES (1, 4)");
    run("UPDATE members SET seen = 160 WHERE fid = 1");
    assert.deepEqual(due(200).get(1), { slot: 200, count: 1, newest: 170, post: kept, authors: [3] });
    assert.equal(due(200).get(2)!.post, muted, "someone else's mute is theirs");
    run("UPDATE members SET seen = 999 WHERE fid = 1");
    assert.deepEqual(due(200).get(1), { slot: 200, count: 0, newest: null, post: null, authors: [] }, "due, with nothing unread");
  });

  test("not a device at another level, or with a key that's gone, and those waiting longest first", () => {
    run("UPDATE push_targets SET level = 'all' WHERE fid = 1");
    run("UPDATE network_keys SET revoked = 1 WHERE fid = 2");
    run("UPDATE push_targets SET digest_slot = 50 WHERE fid = 3");
    assert.deepEqual([...due(200).keys()], [3]);
    run("INSERT INTO push_targets (network_key, fid, relay, handle, key, added, level, digest_slot) VALUES ('k5', 4, 'r', 'h5', 'x', 1, 'digest', 10)");
    run("INSERT INTO network_keys (key, fid, device_key, issued, signature, added) VALUES ('k5', 4, 'd', 1, 's', 1)");
    assert.deepEqual([...due(200, 0, 1).keys()], [4], "the device due since 10 before the one due since 50");
  });

  test("once marked, a device waits for its next slot, and its mark only rises", () => {
    run(PUSH_SQL.digested, JSON.stringify([["k1", 200, 170], ["k2", 200, 0]]));
    assert.deepEqual([...due(200).keys()], [3]);
    const marks = () => db.prepare("SELECT fid, digest_slot, digest_mark FROM push_targets WHERE fid IN (1, 2) ORDER BY fid").all();
    assert.deepEqual(marks().map((row) => ({ ...row })), [{ fid: 1, digest_slot: 200, digest_mark: 170 }, { fid: 2, digest_slot: 200, digest_mark: 0 }]);
    run(PUSH_SQL.digested, JSON.stringify([["k1", 300, 0]]));
    assert.deepEqual({ ...marks()[0] }, { fid: 1, digest_slot: 300, digest_mark: 170 });
  });
});

describe("who hears a new post", () => {
  let db: DatabaseSync;
  const run = (sql: string, ...values: (string | number)[]) => db.prepare(sql).run(...values);

  /** Members 1 to 5, each with a live key and a device set to all posts. */
  beforeEach(() => {
    db = new DatabaseSync(":memory:");
    for (const sql of MIGRATIONS.flat()) db.exec(sql);
    for (const fid of [1, 2, 3, 4, 5]) {
      run("INSERT INTO members (fid, custody, joined, checked) VALUES (?, '0x', 1, 1)", fid);
      run("INSERT INTO network_keys (key, fid, device_key, issued, signature, added) VALUES (?, ?, 'd', 1, 's', 1)", `k${fid}`, fid);
      run("INSERT INTO push_targets (network_key, fid, relay, handle, key, added) VALUES (?, ?, 'r', ?, 'x', 1)", `k${fid}`, fid, `h${fid}`);
    }
  });

  /** Who hears a post by `author` in `hour`, with their count and authors, by FID. */
  const post = (hour: number, author: number, told: number[] = []) => {
    const rows = db.prepare(PUSH_SQL.countPost).all(hour, author, JSON.stringify([author, ...told])) as { fid: number; post_count: number; post_fids: string }[];
    return new Map(rows.map((row) => [row.fid, { count: row.post_count, authors: JSON.parse(row.post_fids) as number[] }]));
  };

  test("everyone but the author counts it, and the count rises through the hour", () => {
    const first = post(100, 2);
    assert.deepEqual([...first.keys()].sort(), [1, 3, 4, 5]);
    assert.deepEqual(first.get(1), { count: 1, authors: [2] });
    assert.deepEqual(post(100, 3).get(1), { count: 2, authors: [3, 2] });
    assert.deepEqual(post(100, 2).get(1), { count: 3, authors: [2, 3] }, "an author is named once, most recent first");
    assert.deepEqual(post(100, 4).get(1), { count: 4, authors: [4, 2, 3] });
    assert.deepEqual(post(100, 5).get(1), { count: 5, authors: [5, 4, 2] }, "three at most");
    assert.deepEqual(post(100, 1).get(2), { count: 4, authors: [1, 5, 4] }, "2 never counted their own two");
  });

  test("a new hour starts again", () => {
    post(100, 2);
    post(100, 3);
    assert.deepEqual(post(101, 4).get(1), { count: 1, authors: [4] });
    assert.deepEqual(post(102, 4).get(1), { count: 1, authors: [4] });
  });

  test("not someone who muted the author, told another way, at another level, or with a key that's gone", () => {
    run("INSERT INTO mutes (fid, muted) VALUES (3, 2)");
    run("UPDATE push_targets SET level = 'replies' WHERE fid = 4");
    run("UPDATE network_keys SET revoked = 1 WHERE fid = 5");
    assert.deepEqual([...post(100, 2, [1]).keys()], []);
    assert.deepEqual([...post(100, 3).keys()].sort(), [1, 2]);
  });
});

describe("the statements' query plans", () => {
  test("none reads a whole table", () => {
    const db = new DatabaseSync(":memory:");
    for (const sql of MIGRATIONS.flat()) db.exec(sql);
    const scans: string[] = [];
    for (const [name, sql] of Object.entries(PUSH_SQL)) {
      for (const { detail } of db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all() as { detail: string }[]) {
        const table = /^SCAN (\w+)/.exec(detail)?.[1];
        // d is digests' own list of due devices, stopped by its LIMIT, not a table.
        if (table && table !== "CONSTANT" && table !== "d" && !detail.includes("VIRTUAL TABLE")) scans.push(`${name}: ${detail}`);
      }
    }
    assert.deepEqual(scans, []);
  });
});
