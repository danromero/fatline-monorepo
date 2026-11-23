import assert from "node:assert/strict";
import { after, describe, test } from "node:test";
import type { NetworkClient } from "../client/client.ts";
import { newPerson } from "../client/local.ts";
import type { PushSettings } from "../src/protocol/api.ts";
import { toHex } from "../src/protocol/protobuf.ts";
import { collapseFor, open } from "../src/protocol/push.ts";
import type { Note } from "../src/protocol/push.ts";
import { nextSlot } from "../src/server/slots.ts";
import { alice, bob, carol, erin, now, rejects, useCabin } from "./fixtures.ts";
import { FakeRelay } from "./relay.ts";

/**
 * Twice a day, against the real Worker on a local D1 and a stand-in relay: the summary at each
 * device's 9 or 21 o'clock, what counts as unread, seen from any device, nothing sent when nothing's
 * new, and each device's own clock. Each run of the hourly job is as if it were a minute past a slot.
 */

const relay = new FakeRelay();
await relay.start();
after(() => relay.stop());
after(() => assert.deepEqual(relay.problems, []));

const fixture = useCabin({ PUSH_RELAYS: relay.url });
const { as } = fixture;

const keys = new Map<string, Uint8Array>();
const handleFor = (name: string) => name.padEnd(22, "0");

/** `client` hears from the network on the handle named `name`, twice a day in UTC unless `choices` say otherwise. */
async function listen(client: NetworkClient, name: string, choices: Partial<PushSettings> = {}) {
  const handle = handleFor(name);
  if (!keys.has(handle)) keys.set(handle, crypto.getRandomValues(new Uint8Array(32)));
  await client.setPush({ relay: relay.url, handle, key: toHex(keys.get(handle)!), tz: "UTC", ...choices });
}

interface Heard {
  note: Note;
  collapse?: string;
}

/** The next call's notes, opened, by the name of the device that heard each. */
async function heard(): Promise<Map<string, Heard>> {
  const out = new Map<string, Heard>();
  for (const sent of await relay.next()) {
    const bytes = await open(keys.get(sent.handle)!, sent.sealed);
    assert.ok(bytes, "a note didn't open");
    out.set(sent.handle.replace(/0+$/, ""), { note: JSON.parse(new TextDecoder().decode(bytes)) as Note, ...(sent.collapse ? { collapse: sent.collapse } : {}) });
  }
  return out;
}

const names = (notes: Map<string, Heard>) => [...notes.keys()].sort();
/** A post's time comes from the second it was signed, and only later posts are unread, so tests wait one out. */
const nextSecond = () => new Promise((resolve) => setTimeout(resolve, 1100));
const timeOf = async (client: NetworkClient, hash: string) => (await client.feed()).posts.find((post) => post.hash === hash)!.time;

/** The hourly job's latest run, as Unix seconds. Each run is later than the last. */
let last = now();
/** Runs the hourly job a minute past `zone`'s next slot. */
async function runAfterSlot(zone = "UTC") {
  last = nextSlot(zone, last) + 60;
  await fixture.network.runHourly(last);
}

/** What a summary says, without the parts a test doesn't name. */
const summary = (heard: Heard | undefined) => heard && { count: heard.note.count, usernames: heard.note.usernames, text: heard.note.text, post: heard.note.post };

describe("twice a day", () => {
  let hike = "";
  let hello = "";
  let cocoa = "";

  test("is the default: a new post waits for the summary, and a reply comes at once", async () => {
    // Alice and bob take the default, carol hears all posts, and erin replies and mentions.
    await listen(as(alice), "alice-phone");
    await listen(as(bob), "bob-phone");
    await listen(as(carol), "carol-phone", { level: "all" });
    await listen(as(erin), "erin-phone", { level: "replies" });
    await nextSecond();

    hike = await as(bob).post({ text: "Hike?" });
    assert.deepEqual(names(await heard()), ["carol-phone"]);
    hello = await as(alice).post({ text: "Hello" });
    assert.deepEqual(names(await heard()), ["carol-phone"]);
    await as(bob).reply({ fid: alice.fid, hash: hello }, { text: "Hi" });
    const notes = await heard();
    assert.deepEqual(names(notes), ["alice-phone"]);
    assert.equal(notes.get("alice-phone")!.note.kind, "reply");
  });

  test("the first 9 or 21 o'clock after something new brings what's unread, each device once", async () => {
    // A minute before the slot, nothing's due. (Skipped when the slot is less than a minute away.)
    const slot = nextSlot("UTC", last);
    if (slot - 60 > last) {
      await fixture.network.runHourly(slot - 60);
      await relay.quiet();
    }
    await runAfterSlot();
    const notes = await heard();
    assert.deepEqual(names(notes), ["alice-phone", "bob-phone"], "not carol, set to all posts, or erin, set to replies");
    const toAlice = notes.get("alice-phone")!;
    assert.deepEqual(toAlice.note, { v: 1, kind: "post", fid: bob.fid, username: "bob", text: "Hike?", pictures: 0, post: hike, thread: hike, count: 1, usernames: ["bob"] },
      "one post says what it says; replies don't count");
    assert.equal(toAlice.collapse, await collapseFor(handleFor("alice-phone"), "digest"));
    assert.deepEqual(summary(notes.get("bob-phone")), { count: 1, usernames: ["alice"], text: "Hello", post: hello }, "not bob's own post");

    // The same slot again sends nothing.
    await fixture.network.runHourly(last + 60);
    await relay.quiet();
  });

  test("nothing new since the last summary, nothing sent, though it's still unread", async () => {
    // Carol's done her part: from here on, her device setting all posts would hear every post at once.
    await listen(as(carol), "carol-phone", { level: "off" });
    await runAfterSlot();
    await relay.quiet();
  });

  test("the next summary counts everything unread, and replaces the last", async () => {
    await nextSecond();
    cocoa = await as(carol).post({ text: "Cocoa" });
    await relay.quiet();
    await runAfterSlot();
    const notes = await heard();
    assert.deepEqual(names(notes), ["alice-phone", "bob-phone"]);
    assert.deepEqual(summary(notes.get("alice-phone")), { count: 2, usernames: ["carol", "bob"], text: "", post: cocoa }, "newest first");
    assert.deepEqual(summary(notes.get("bob-phone")), { count: 2, usernames: ["carol", "alice"], text: "", post: cocoa });
    assert.equal(notes.get("alice-phone")!.collapse, await collapseFor(handleFor("alice-phone"), "digest"), "the same collapse as the last");
  });

  test("what the member read on another device is left out", async () => {
    const laptop = await fixture.network.device(alice);
    assert.equal(await laptop.join(), "approved");
    assert.equal(await laptop.signIn(), "approved");
    await laptop.setSeen(await timeOf(laptop, cocoa));
    await nextSecond();
    const late = await as(bob).post({ text: "Late" });
    await runAfterSlot();
    let notes = await heard();
    assert.deepEqual(names(notes), ["alice-phone"], "bob has nothing new but his own");
    assert.deepEqual(summary(notes.get("alice-phone")), { count: 1, usernames: ["bob"], text: "Late", post: late });

    // Read before the slot: nothing for alice.
    await nextSecond();
    const again = await as(carol).post({ text: "Again" });
    await laptop.setSeen(await timeOf(laptop, again));
    await runAfterSlot();
    notes = await heard();
    assert.deepEqual(names(notes), ["bob-phone"]);
    assert.deepEqual(summary(notes.get("bob-phone")), { count: 3, usernames: ["carol", "alice"], text: "", post: again });
  });

  test("seen only moves forward, and never past now", async () => {
    await as(alice).setSeen(now() + 10 * 24 * 60 * 60);
    await as(alice).setSeen(0);
    await rejects(as(alice).setSeen(-1), 400, /time/);
    await rejects(as(alice).setSeen(1.5), 400, /time/);
    await nextSecond();
    const future = await as(bob).post({ text: "Future" });
    await runAfterSlot();
    const notes = await heard();
    assert.deepEqual(names(notes), ["alice-phone"]);
    assert.deepEqual(summary(notes.get("alice-phone")), { count: 1, usernames: ["bob"], text: "Future", post: future });
  });

  test("leaves out someone muted, your own posts, and deleted posts", async () => {
    await as(bob).setSeen(now());
    await as(alice).mute(carol.fid);
    await nextSecond();
    const muted = await as(carol).post({ text: "Muted" });
    await nextSecond();
    const mine = await as(alice).post({ text: "Mine" });
    const gone = await as(bob).post({ text: "Gone" });
    await as(bob).remove(gone);
    await runAfterSlot();
    const notes = await heard();
    assert.deepEqual(names(notes), ["bob-phone"], "alice has nothing she'd see");
    assert.deepEqual(summary(notes.get("bob-phone")), { count: 2, usernames: ["alice", "carol"], text: "", post: mine });
    assert.ok(muted);
    await as(alice).unmute(carol.fid);
  });

  test("follows each device's own clock", async () => {
    await rejects(as(erin).setPush({ relay: relay.url, handle: handleFor("erin-phone"), key: toHex(keys.get(handleFor("erin-phone"))!), tz: "Not a zone!" }), 400, /tz/);
    // A well-formed zone this server doesn't know is UTC.
    await listen(as(erin), "erin-phone", { level: "replies", tz: "Mars/Olympus" });

    await listen(as(bob), "bob-phone", { tz: "Asia/Kolkata" });
    await as(alice).setSeen(now());
    await as(bob).setSeen(now());
    await nextSecond();
    const zone = await as(carol).post({ text: "Zone" });
    // Kolkata's 9 or 21 o'clock, 3:30 or 15:30 UTC, comes before UTC's next.
    const kolkata = nextSlot("Asia/Kolkata", last);
    assert.ok(kolkata < nextSlot("UTC", last));
    await runAfterSlot("Asia/Kolkata");
    let notes = await heard();
    assert.deepEqual(names(notes), ["bob-phone"]);
    assert.deepEqual(summary(notes.get("bob-phone")), { count: 1, usernames: ["carol"], text: "Zone", post: zone });
    await runAfterSlot("UTC");
    notes = await heard();
    assert.deepEqual(names(notes), ["alice-phone"]);
  });

  test("a new device's first summary counts only posts after it was added", async () => {
    const gina = newPerson(1301, "gina");
    assert.equal(await fixture.joined(gina, (await as(alice).createInvite()).code), "approved");
    assert.equal(await as(gina).signIn(), "approved");
    await listen(as(gina), "gina-phone");
    await runAfterSlot();
    await relay.quiet();
    await nextSecond();
    const first = await as(carol).post({ text: "Welcome, gina" });
    await runAfterSlot();
    const notes = await heard();
    assert.deepEqual(summary(notes.get("gina-phone")), { count: 1, usernames: ["carol"], text: "Welcome, gina", post: first });
  });
});
