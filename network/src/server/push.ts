import { fromHex } from "../protocol/protobuf.ts";
import { joinMentions } from "../protocol/text.ts";
import { collapseFor, hourOf, noteBytes, seal } from "../protocol/push.ts";
import type { Note, NoteKind } from "../protocol/push.ts";
import type { TestPushResult } from "../protocol/api.ts";
import { checkDaily, countDaily } from "./daily.ts";
import type { Context, Env, Viewer } from "./env.ts";
import { badRequest, booleanField, choiceField, field, json, noContent, problem, readJSON } from "./http.ts";
import { displayUsername } from "./identity.ts";
import { PUSH_SQL } from "./pushsql.ts";
import { knownZone, lastSlot } from "./slots.ts";
import { usernames as allUsernames } from "./store.ts";

/**
 * Notifications, as docs/NETWORK.md describes: where each device hears from this network, and the
 * sealed notes sent there through a relay. Each trigger runs behind the answer, once its write is in.
 * Nothing is tried again: a note that doesn't get through is a missed notification, never a lost post.
 */

export const DEFAULT_RELAY = "https://push.fatline.tech";
/** The most notes a relay takes in one call. */
const NOTES_PER_CALL = 40;
/** Calls to relays for one event, well inside the 50 requests a Worker on the free plan may make. */
const CALLS_PER_EVENT = 20;
const RELAY_TIMEOUT_MS = 10_000;
/** 16 random bytes from the relay, as base64url. The relay refuses a whole call with one malformed handle in it. */
const HANDLE = /^[A-Za-z0-9_-]{22}$/;
/** "digest", twice a day, is the default: new posts in a summary at 9 a.m. and 9 p.m., replies and mentions at once. */
const LEVELS = ["digest", "all", "replies", "off"] as const;
/** Relay calls the hourly job's summaries may make, ahead of everything else it fetches: 320 devices an hour. */
export const DIGEST_CALLS = 8;

export interface PushTarget {
  relay: string;
  handle: string;
  /** The device's 32-byte key for this network, as 0x-prefixed hex. */
  key: string;
  /** Where the device is, such as America/New_York, for when its summaries go. Kept as it was when not sent. */
  tz?: string;
}

export interface PushChoices {
  level: (typeof LEVELS)[number];
  requests: boolean;
  reports: boolean;
}

/** A relay as the server compares them: an http(s) URL with no query, fragment, or trailing slash. */
function normalRelay(text: string): string | null {
  let url: URL;
  try {
    url = new URL(text.trim());
  } catch {
    return null;
  }
  if ((url.protocol !== "https:" && url.protocol !== "http:") || url.search || url.hash || url.username || url.password) return null;
  return url.href.replace(/\/+$/, "");
}

/** The relays PUSH_RELAYS lists, read on every use, so taking one off stops notes to it at once. */
export function relays(env: Env): string[] {
  const value = env.PUSH_RELAYS?.trim();
  if (!value) return [DEFAULT_RELAY];
  if (value.toLowerCase() === "none") return [];
  return value.split(",").flatMap((item) => normalRelay(item) ?? []);
}

/** `push`'s relay, handle, and key, checked. A relay this network doesn't list answers `unknown-relay`. */
export function pushFields(env: Env, push: Record<string, unknown>): PushTarget {
  const relayText = push.relay;
  if (typeof relayText !== "string" || relayText.length > 512) throw badRequest("relay should be a link of at most 512 characters.");
  const handle = push.handle;
  if (typeof handle !== "string" || !HANDLE.test(handle)) throw badRequest("handle should be 22 characters from A-Z a-z 0-9 - _");
  const key = field.hex(push, "key", 32);
  const tz = zoneField(push.tz);
  const relay = normalRelay(relayText);
  if (!relay || !relays(env).includes(relay)) throw problem("unknown-relay");
  return { relay, handle, key, ...(tz ? { tz } : {}) };
}

/**
 * `tz`: a time zone's name. One this server's clock doesn't know, as a newer phone might send, is UTC,
 * so the device still hears its summaries, at the wrong hour, rather than its whole request failing.
 */
function zoneField(value: unknown): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "string" || !/^[A-Za-z][A-Za-z0-9_+/-]{0,63}$/.test(value)) throw badRequest("tz should be a time zone, such as America/New_York.");
  return knownZone(value) ?? "UTC";
}

/**
 * Keeps `push` as where `networkKey` hears from this network, while that key is live. A handle is one
 * device's, so another key that had it lets it go. Without `choices`, as when joining, a new device
 * hears new posts twice a day and one that chose already keeps its choices. A new device's first
 * summary is at the first slot after it was added.
 */
export function targetStatements(context: Context, fid: number, networkKey: string, push: PushTarget, choices?: PushChoices): D1PreparedStatement[] {
  const db = context.db;
  const chosen = choices ? ", level = excluded.level, requests = excluded.requests, reports = excluded.reports" : "";
  return [
    db.prepare("DELETE FROM push_targets WHERE handle = ?1 AND relay = ?2 AND network_key != ?3").bind(push.handle, push.relay, networkKey),
    db.prepare(`INSERT INTO push_targets (network_key, fid, relay, handle, key, level, requests, reports, added, tz, digest_slot)
        SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, COALESCE(?10, 'UTC'), ?9
        WHERE EXISTS (SELECT 1 FROM network_keys WHERE key = ?1 AND fid = ?2 AND revoked IS NULL)
        ON CONFLICT (network_key) DO UPDATE SET relay = excluded.relay, handle = excluded.handle, key = excluded.key,
          tz = COALESCE(?10, push_targets.tz)${chosen}`)
      .bind(networkKey, fid, push.relay, push.handle, push.key, choices?.level ?? "digest", choices?.requests === false ? 0 : 1,
        choices?.reports === false ? 0 : 1, context.now, push.tz ?? null),
  ];
}

/** PUT /me/push. */
export async function setPush(context: Context, viewer: Viewer, request: Request) {
  const body = await readJSON(request);
  const push = pushFields(context.env, body);
  const choices: PushChoices = {
    level: choiceField(body.level, "level", LEVELS) ?? "digest",
    requests: booleanField(body.requests, "requests") ?? true,
    reports: booleanField(body.reports, "reports") ?? true,
  };
  await context.db.batch(targetStatements(context, viewer.fid, viewer.networkKey, push, choices));
  return noContent();
}

/** DELETE /me/push. */
export async function removePush(context: Context, viewer: Viewer) {
  await context.db.prepare("DELETE FROM push_targets WHERE network_key = ?").bind(viewer.networkKey).run();
  return noContent();
}

/**
 * PUT /me/seen: `time` is the newest post this member has had on screen, on whichever device. Seen
 * only moves forward, and never past now, so one device can't hide what another hasn't shown.
 */
export async function setSeen(context: Context, viewer: Viewer, request: Request) {
  const body = await readJSON(request);
  const time = body.time;
  if (typeof time !== "number" || !Number.isSafeInteger(time) || time < 0) throw badRequest("time should be a post's time, in seconds.");
  await context.db.prepare("UPDATE members SET seen = MAX(seen, MIN(?1, ?2)) WHERE fid = ?3").bind(time, context.now, viewer.fid).run();
  return noContent();
}

/**
 * POST /me/push/test: a test note to the device whose network key asks, from Debug in the app. It goes
 * now, not behind the answer, so the app can say what the relay said. 20 a day per member.
 */
export async function testPush(context: Context, viewer: Viewer) {
  await checkDaily(context, viewer.fid, "tests", "That's enough test notifications for today. Try again tomorrow.");
  const target = await context.db.prepare("SELECT network_key, fid, relay, handle, key FROM push_targets WHERE network_key = ?")
    .bind(viewer.networkKey).first<Target>();
  const key = target ? fromHex(target.key) : null;
  if (!target || key?.length !== 32) throw problem("no-push");
  if (!relays(context.env).includes(target.relay)) throw problem("unknown-relay");
  await countDaily(context, viewer.fid, "tests").run();
  const note = plain("test", viewer.fid, await username(context, viewer.fid));
  const answer = await send(context, target.relay, [{ handle: target.handle, sealed: await seal(key, noteBytes(note)) }]);
  let result: TestPushResult;
  if ("refused" in answer) result = { result: "failed", reason: answer.refused };
  else if (answer.gone.includes(target.handle)) result = { result: "gone", reason: answer.failed.get(target.handle) ?? "unknown-handle" };
  else if (answer.failed.has(target.handle)) result = { result: "failed", reason: answer.failed.get(target.handle)! };
  else result = { result: "sent" };
  return json(result);
}

// MARK: Who hears what

interface Target {
  network_key: string;
  fid: number;
  relay: string;
  handle: string;
  key: string;
}

interface Outgoing {
  target: Target;
  note: Note;
  collapse?: string;
}

async function select(context: Context, sql: string, ...params: unknown[]): Promise<Target[]> {
  return (await context.db.prepare(sql).bind(...params).all<Target>()).results;
}

async function username(context: Context, fid: number) {
  const row = await context.db.prepare(PUSH_SQL.username).bind(fid).first<{ username: string | null }>();
  return displayUsername(fid, row?.username ?? null);
}

/** A note about no post. */
const plain = (kind: NoteKind, fid: number, name: string, text = "", post: string | null = null, thread: string | null = null): Note =>
  ({ v: 1, kind, fid, username: name, text, pictures: 0, post, thread });

/** Runs `work` behind the answer. What fails is logged, not tried again. */
function later(context: Context, what: string, work: () => Promise<void>) {
  context.waitUntil(work().catch((error) => console.error(`${what} notifications failed`, String(error))));
}

export interface NewPost {
  fid: number;
  hash: string;
  parent: string | null;
  parentFid: number | null;
  /** With mentions as @username. */
  text: string;
  /** Members it mentions, without its author. */
  mentioned: number[];
  pictures: number;
  /** Every member's username, as the post was checked with. */
  names: Map<number, string>;
}

/**
 * A new post or reply. The post's author hears of a reply, the members it mentions of a mention, and
 * everyone set to all posts of a post, grouped by the hour. One note per event: a reply that also
 * mentions you is a reply, and a post that mentions you is a mention. Nobody hears of their own post,
 * or of one from someone they muted.
 */
export function notifyPost(context: Context, post: NewPost) {
  later(context, "post", async () => {
    const author = post.names.get(post.fid) ?? displayUsername(post.fid, null);
    const note = (kind: NoteKind): Note =>
      ({ v: 1, kind, fid: post.fid, username: author, text: post.text, pictures: post.pictures, post: post.hash, thread: post.parent ?? post.hash });
    const outgoing: Outgoing[] = [];
    const told = new Set([post.fid]);
    if (post.parentFid !== null && !told.has(post.parentFid)) {
      for (const target of await select(context, PUSH_SQL.reply, post.parentFid, post.fid)) outgoing.push({ target, note: note("reply") });
      told.add(post.parentFid);
    }
    const mentioned = [...new Set(post.mentioned)].filter((fid) => !told.has(fid));
    if (mentioned.length) {
      for (const target of await select(context, PUSH_SQL.mention, JSON.stringify(mentioned), post.fid)) outgoing.push({ target, note: note("mention") });
      for (const fid of mentioned) told.add(fid);
    }
    if (post.parent === null) {
      const hour = hourOf(context.now);
      const counted = await context.db.prepare(PUSH_SQL.countPost).bind(hour, post.fid, JSON.stringify([...told]))
        .all<Target & { post_count: number; post_fids: string }>();
      // A post costs what it writes, so its author's day counts the row it moves for each device it reaches.
      const written = counted.meta.rows_written ?? 0;
      if (written > 0) await countDaily(context, post.fid, "writes", written).run();
      for (const row of counted.results) {
        const usernames = (JSON.parse(row.post_fids) as number[]).map((fid) => post.names.get(fid) ?? displayUsername(fid, null));
        outgoing.push({ target: row, note: { ...note("post"), count: row.post_count, usernames }, collapse: await collapseFor(row.handle, hour) });
      }
    }
    await deliver(context, outgoing);
  });
}

// MARK: Twice a day

interface Due extends Target {
  slot: number;
  digest_mark: number;
  count: number;
  newest: number | null;
  post: string | null;
  fids: string;
}

/**
 * The hourly job's summaries: each device set to twice a day whose 9 or 21 o'clock has come since it
 * was last due hears how many posts it hasn't read, if any came since its last summary. Nothing new,
 * nothing sent, even with posts still unread. Each summary replaces the device's last one. A device
 * past the first 320 waits for the next run. Answers how many relay calls it made, for the job's budget.
 */
export async function sendDigests(context: Context): Promise<number> {
  const zones = (await context.db.prepare(PUSH_SQL.zones).all<{ tz: string }>()).results;
  if (!zones.length) return 0;
  const slots = zones.map(({ tz }) => [tz, lastSlot(tz, context.now)]);
  const due = (await context.db.prepare(PUSH_SQL.digests).bind(JSON.stringify(slots), DIGEST_CALLS * NOTES_PER_CALL).all<Due>()).results;
  if (!due.length) return 0;
  const going = due.filter((row) => row.count > 0 && row.newest !== null && row.newest > row.digest_mark && row.post !== null);
  const names = going.length ? await allUsernames(context) : new Map<number, string>();
  const name = (fid: number) => names.get(fid) ?? displayUsername(fid, null);
  // A summary of one post says what it says, as a new post's note does.
  const single = [...new Set(going.filter((row) => row.count === 1).map((row) => row.post!))];
  const posts = new Map<string, { text: string; pictures: number }>();
  if (single.length) {
    const rows = await context.db.prepare(PUSH_SQL.digestPosts).bind(JSON.stringify(single))
      .all<{ hash: string; text: string; mentions: string; embeds: string }>();
    for (const row of rows.results) {
      const mentions = JSON.parse(row.mentions) as { fid: number; position: number }[];
      const text = joinMentions({ text: row.text, fids: mentions.map((item) => item.fid), positions: mentions.map((item) => item.position) }, names);
      const pictures = (JSON.parse(row.embeds) as { kind: string }[]).filter((item) => item.kind === "image").length;
      posts.set(row.hash, { text, pictures });
    }
  }
  const outgoing: Outgoing[] = [];
  for (const row of going) {
    const authors = JSON.parse(row.fids) as number[];
    const shown = row.count === 1 ? posts.get(row.post!) : undefined;
    const note: Note = {
      v: 1, kind: "post", fid: authors[0]!, username: name(authors[0]!), text: shown?.text ?? "", pictures: shown?.pictures ?? 0,
      post: row.post, thread: row.post, count: row.count, usernames: authors.map(name),
    };
    outgoing.push({ target: row, note, collapse: await collapseFor(row.handle, "digest") });
  }
  // Due once, whether or not a summary went, so a device isn't looked at again until its next slot.
  const marks = due.map((row) => [row.network_key, row.slot, going.includes(row) ? row.newest : 0]);
  await context.db.prepare(PUSH_SQL.digested).bind(JSON.stringify(marks)).run();
  return deliver(context, outgoing, DIGEST_CALLS);
}

/** Someone who waited is let in, by the admin or by a follow: their devices hear "You're in". */
export function notifyApproved(context: Context, fid: number) {
  later(context, "approval", async () => {
    const targets = await select(context, PUSH_SQL.approved, fid);
    if (!targets.length) return;
    const note = plain("approved", fid, await username(context, fid));
    await deliver(context, targets.map((target) => ({ target, note })));
  });
}

/** Someone asked to join: the admin hears of it, unless they turned join requests off. */
export function notifyRequest(context: Context, fid: number, name: string | null) {
  const admin = context.adminFid;
  if (admin === null || admin === fid) return;
  later(context, "request", async () => {
    const note = plain("request", fid, displayUsername(fid, name));
    await deliver(context, (await select(context, PUSH_SQL.requests, admin)).map((target) => ({ target, note })));
  });
}

/** A member reported a post: the admin hears of it, unless they turned reports off or reported it. */
export function notifyReport(context: Context, report: { fid: number; post: string; thread: string; note: string }) {
  const admin = context.adminFid;
  if (admin === null || admin === report.fid) return;
  later(context, "report", async () => {
    const targets = await select(context, PUSH_SQL.reports, admin);
    if (!targets.length) return;
    const note = plain("report", report.fid, await username(context, report.fid), report.note, report.post, report.thread);
    await deliver(context, targets.map((target) => ({ target, note })));
  });
}

// MARK: Sending

interface Sealed {
  handle: string;
  sealed: string;
  collapse?: string;
}

/**
 * Seals each note for its device and sends them, 40 to a call, to relays this network still lists,
 * in at most `calls` calls. Answers how many it made.
 */
async function deliver(context: Context, outgoing: Outgoing[], most = CALLS_PER_EVENT): Promise<number> {
  const listed = new Set(relays(context.env));
  const byRelay = new Map<string, Sealed[]>();
  const seen = new Set<string>();
  for (const { target, note, collapse } of outgoing) {
    const key = fromHex(target.key);
    const id = `${target.relay} ${target.handle}`;
    if (!listed.has(target.relay) || seen.has(id) || key?.length !== 32) continue;
    seen.add(id);
    const notes = byRelay.get(target.relay) ?? [];
    notes.push({ handle: target.handle, sealed: await seal(key, noteBytes(note)), ...(collapse ? { collapse } : {}) });
    byRelay.set(target.relay, notes);
  }
  let calls = 0;
  for (const [relay, notes] of byRelay) {
    for (let at = 0; at < notes.length && calls < most; at += NOTES_PER_CALL, calls++) {
      await send(context, relay, notes.slice(at, at + NOTES_PER_CALL));
    }
  }
  return calls;
}

/** What a relay said of a call: the handles it says are gone, and why each note it didn't pass on didn't go. */
type RelayAnswer = { gone: string[]; failed: Map<string, string> } | { refused: string };

/** One call to a relay. Handles it says are gone, of those sent, go here too. */
async function send(context: Context, relay: string, notes: Sealed[]): Promise<RelayAnswer> {
  let response: Response;
  try {
    response = await fetch(`${relay}/send`, {
      method: "POST",
      headers: { "content-type": "application/json", "user-agent": "FatlineNetwork/1 (notifications)" },
      body: JSON.stringify({ notes }),
      redirect: "manual",
      signal: AbortSignal.timeout(RELAY_TIMEOUT_MS),
    });
  } catch (error) {
    console.error("relay unreachable", relay, String(error));
    return { refused: "relay-unreachable" };
  }
  if (!response.ok) {
    console.error("relay refused notes", relay, response.status);
    await response.body?.cancel();
    return { refused: `relay-${response.status}` };
  }
  const answer = (await response.json().catch(() => null)) as { gone?: unknown; failed?: unknown } | null;
  const sent = new Set(notes.map((note) => note.handle));
  const gone = Array.isArray(answer?.gone) ? answer.gone.filter((handle): handle is string => typeof handle === "string" && sent.has(handle)) : [];
  if (gone.length) await context.db.prepare(PUSH_SQL.gone).bind(relay, JSON.stringify(gone)).run();
  // Newer relays say why; a reason is a short word of letters, digits, and hyphens, or it's left out.
  const failed = new Map<string, string>();
  for (const item of Array.isArray(answer?.failed) ? answer.failed : []) {
    const { handle, reason } = (item ?? {}) as { handle?: unknown; reason?: unknown };
    if (typeof handle === "string" && sent.has(handle) && typeof reason === "string" && /^[A-Za-z0-9-]{1,64}$/.test(reason)) failed.set(handle, reason);
  }
  return { gone, failed };
}
