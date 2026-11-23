import assert from "node:assert/strict";
import { after, describe, test } from "node:test";
import { NetworkClient } from "../client/client.ts";
import { newPerson, TEST_PNG } from "../client/local.ts";
import type { PushSettings } from "../src/protocol/api.ts";
import { imageURL } from "../src/protocol/messages.ts";
import { toHex } from "../src/protocol/protobuf.ts";
import { collapseFor, hourOf, open } from "../src/protocol/push.ts";
import type { Note } from "../src/protocol/push.ts";
import { alice, bob, carol, erin, frank, handles, now, rejects, useCabin } from "./fixtures.ts";
import { FakeRelay } from "./relay.ts";

/**
 * Notifications, against the real Worker on a local D1 and a stand-in relay that opens nothing: who
 * hears what at each level, one note per event, new posts grouped by the hour, mutes, a relay the
 * network doesn't list, and devices that stop hearing.
 */

const relay = new FakeRelay();
await relay.start();
after(() => relay.stop());

const fixture = useCabin({ PUSH_RELAYS: `https://push.example, ${relay.url}` });
const { as } = fixture;

/** Each device's key, by its handle. Handles are 22 characters, as the relay makes them. */
const keys = new Map<string, Uint8Array>();
const handleFor = (name: string) => name.padEnd(22, "0");
const newKey = (handle: string) => {
  const key = crypto.getRandomValues(new Uint8Array(32));
  keys.set(handle, key);
  return toHex(key);
};

/** `client` hears from the network on the handle named `name`, all posts unless `choices` say otherwise. */
async function listen(client: NetworkClient, name: string, choices: Partial<PushSettings> = {}) {
  const handle = handleFor(name);
  await client.setPush({ relay: relay.url, handle, key: keys.has(handle) ? toHex(keys.get(handle)!) : newKey(handle), level: "all", ...choices });
}

interface Heard {
  note: Note;
  collapse?: string;
}

/** The next event's notes, opened, by the name of the device that heard each. */
async function heard(): Promise<Map<string, Heard>> {
  const out = new Map<string, Heard>();
  for (const sent of await relay.next()) {
    const name = sent.handle.replace(/0+$/, "");
    assert.ok(!out.has(name), `${name} heard twice`);
    assert.ok(sent.sealed.length < 3072, `a sealed note of ${sent.sealed.length} characters`);
    const bytes = await open(keys.get(sent.handle)!, sent.sealed);
    assert.ok(bytes, `${name}'s note didn't open`);
    const note = JSON.parse(new TextDecoder().decode(bytes)) as Note;
    assert.equal(sent.collapse !== undefined, note.kind === "post", "only new posts collapse");
    out.set(name, sent.collapse ? { note, collapse: sent.collapse } : { note });
  }
  return out;
}

const names = (notes: Map<string, Heard>) => [...notes.keys()].sort();

/** Waits out the last few seconds of an hour, so posts a test counts land in one. */
async function clearOfTheHour() {
  const left = 3600 - (now() % 3600);
  if (left < 20) await new Promise((resolve) => setTimeout(resolve, (left + 1) * 1000));
}

after(() => assert.deepEqual(relay.problems, []));

describe("notifications", () => {
  test("PUT /me/push takes a relay this network lists, and refuses any other", async () => {
    const handle = handleFor("bob-phone");
    const response = await fixture.network.fetch("/api/v1/me/push", {
      method: "PUT",
      headers: { authorization: `Bearer ${as(bob).membership.token}`, "content-type": "application/json" },
      body: JSON.stringify({ relay: "https://elsewhere.example", handle, key: newKey(handle) }),
    });
    assert.equal(response.status, 400);
    assert.equal(((await response.json()) as { code: string }).code, "unknown-relay");
    await rejects(as(bob).setPush({ relay: `${relay.url}/send`, handle, key: newKey(handle) }), 400, /relay/);
    await rejects(as(bob).setPush({ relay: relay.url, handle: "short", key: newKey(handle) }), 400, /handle/);
    await rejects(as(bob).setPush({ relay: relay.url, handle, key: "0x1234" }), 400, /key/);
    await rejects(as(bob).setPush({ relay: relay.url, handle, key: newKey(handle), level: "everything" as "all" }), 400, /level/);
    assert.equal((await fixture.network.fetch("/api/v1/me/push", { method: "PUT", body: "{}" })).status, 401);

    // A trailing slash is the same relay.
    await as(alice).setPush({ relay: `${relay.url}/`, handle: handleFor("alice-phone"), key: newKey(handleFor("alice-phone")), level: "all" });
    await listen(as(bob), "bob-phone");
    await listen(as(carol), "carol-phone", { level: "replies" });
    await listen(as(erin), "erin-phone", { level: "off" });
    await relay.quiet();
  });

  test("a new post reaches everyone set to all posts but its author, grouped by the hour", async () => {
    await clearOfTheHour();
    const hike = await as(bob).post({ text: "Anyone up for a hike?" });
    let notes = await heard();
    assert.deepEqual(names(notes), ["alice-phone"], "carol hears replies and mentions, erin nothing, bob not his own");
    const first = notes.get("alice-phone")!;
    const { count } = first.note;
    assert.deepEqual({ ...first.note, count: 0 },
      { v: 1, kind: "post", fid: bob.fid, username: "bob", text: "Anyone up for a hike?", pictures: 0, post: hike, thread: hike, count: 0, usernames: ["bob"] });
    assert.equal(first.collapse, await collapseFor(handleFor("alice-phone"), hourOf(now())));

    const yes = await as(alice).post({ text: "Me" });
    notes = await heard();
    assert.deepEqual(names(notes), ["bob-phone"]);
    assert.equal(notes.get("bob-phone")!.note.post, yes);
    const bobCount = notes.get("bob-phone")!.note.count!;

    const picture = await as(bob).uploadImage(TEST_PNG, "image/png");
    const trail = await as(bob).post({ text: "", embeds: [{ url: imageURL(fixture.network.host, picture.id) }] });
    notes = await heard();
    const second = notes.get("alice-phone")!;
    assert.deepEqual([second.note.post, second.note.text, second.note.pictures], [trail, "", 1]);
    assert.deepEqual([second.note.count, second.note.usernames], [count! + 1, ["bob"]], "the count rises, and bob is named once");
    assert.equal(second.collapse, first.collapse, "the same hour replaces the last notification");

    await as(carol).post({ text: "Cocoa after" });
    notes = await heard();
    assert.deepEqual(names(notes), ["alice-phone", "bob-phone"]);
    assert.deepEqual([notes.get("alice-phone")!.note.count, notes.get("alice-phone")!.note.usernames], [count! + 2, ["carol", "bob"]]);
    assert.deepEqual([notes.get("bob-phone")!.note.count, notes.get("bob-phone")!.note.usernames], [bobCount + 1, ["carol", "alice"]]);
  });

  test("a reply reaches the post's author, and a mention whom it mentions, one note each", async () => {
    const people = await handles(as(bob));
    const drive = await as(carol).post({ text: "Who's driving?" });
    await heard();

    const offer = await as(bob).reply({ fid: carol.fid, hash: drive }, { text: "I can @carol", handles: people });
    let notes = await heard();
    assert.deepEqual(names(notes), ["carol-phone"], "replies to others' posts reach nobody else");
    assert.deepEqual(notes.get("carol-phone")!.note,
      { v: 1, kind: "reply", fid: bob.fid, username: "bob", text: "I can @carol", pictures: 0, post: offer, thread: drive }, "a reply, not a mention too");

    await as(alice).reply({ fid: carol.fid, hash: drive }, { text: "Thanks @bob", handles: people });
    notes = await heard();
    assert.deepEqual(names(notes), ["bob-phone", "carol-phone"]);
    assert.equal(notes.get("carol-phone")!.note.kind, "reply");
    assert.deepEqual([notes.get("bob-phone")!.note.kind, notes.get("bob-phone")!.note.text, notes.get("bob-phone")!.note.thread], ["mention", "Thanks @bob", drive]);

    // Erin turned notifications off, so a reply to her reaches nobody.
    const quiet = await as(erin).post({ text: "Shh" });
    await heard();
    await as(bob).reply({ fid: erin.fid, hash: quiet }, { text: "Sorry" });
    await relay.quiet();

    await as(bob).post({ text: "@carol @alice see above", handles: people });
    notes = await heard();
    assert.deepEqual(names(notes), ["alice-phone", "carol-phone"]);
    assert.deepEqual([notes.get("alice-phone")!.note.kind, notes.get("carol-phone")!.note.kind], ["mention", "mention"], "a mention, not a new post too");
  });

  test("nothing from someone you muted, except a report", async () => {
    const people = await handles(as(bob));
    const plans = await as(carol).post({ text: "Plans" });
    await heard();
    await as(alice).mute(bob.fid);
    await as(carol).mute(bob.fid);
    await as(bob).post({ text: "Hello?" });
    await relay.quiet();
    await as(bob).reply({ fid: carol.fid, hash: plans }, { text: "Hi @alice", handles: people });
    await relay.quiet();

    const rude = await as(carol).reply({ fid: carol.fid, hash: plans }, { text: "Rude" });
    await relay.quiet();
    await as(bob).report(rude, "Not nice");
    const notes = await heard();
    assert.deepEqual(names(notes), ["alice-phone"]);
    assert.deepEqual(notes.get("alice-phone")!.note,
      { v: 1, kind: "report", fid: bob.fid, username: "bob", text: "Not nice", pictures: 0, post: rude, thread: plans });
    await as(alice).unmute(bob.fid);
    await as(carol).unmute(bob.fid);
  });

  test("the admin hears a join request, and the request hears You're in through the push its join carried", async () => {
    fixture.network.farcaster.add(frank);
    const phone = await fixture.network.device(frank);
    assert.equal(await phone.join(), "pending");
    let notes = await heard();
    assert.deepEqual(names(notes), ["alice-phone"]);
    assert.deepEqual(notes.get("alice-phone")!.note, { v: 1, kind: "request", fid: frank.fid, username: "frank", text: "", pictures: 0, post: null, thread: null });

    // The app asks iOS once Request sent shows, then sends the same join again with its push.
    const handle = handleFor("frank-phone");
    assert.equal(await phone.join({ push: { relay: relay.url, handle, key: newKey(handle) } }), "pending");
    await relay.quiet();
    await as(alice).approve(frank.fid);
    notes = await heard();
    assert.deepEqual(names(notes), ["frank-phone"]);
    assert.deepEqual(notes.get("frank-phone")!.note, { v: 1, kind: "approved", fid: frank.fid, username: "frank", text: "", pictures: 0, post: null, thread: null });
    fixture.devices.set(frank.fid, phone);
    assert.equal(await phone.signIn(), "approved");

    // Their device hears new posts twice a day, the default, until it chooses all posts.
    await as(bob).post({ text: "Welcome, frank" });
    assert.deepEqual(names(await heard()), ["alice-phone"]);
    await listen(as(frank), "frank-phone");
    await as(bob).post({ text: "Frank hears this" });
    assert.deepEqual(names(await heard()), ["alice-phone", "frank-phone"]);
  });

  test("a join naming a relay this network doesn't list is refused, and spends nothing", async () => {
    const gina = newPerson(1401, "gina");
    fixture.network.farcaster.add(gina);
    const code = await as(alice).createInvite();
    const handle = handleFor("gina-phone");
    await rejects((await fixture.network.device(gina)).join({ invite: code.code, push: { relay: "https://elsewhere.example", handle, key: newKey(handle) } }),
      400, /relay/);
    assert.equal((await as(alice).invites()).find((invite) => invite.code === code.code)!.used, 0);
    await relay.quiet();
  });

  test("the admin can turn off requests and reports, and never hears of their own report", async () => {
    await listen(as(alice), "alice-phone", { requests: false });
    const hank = newPerson(1402, "hank");
    fixture.network.farcaster.add(hank);
    assert.equal(await (await fixture.network.device(hank)).join(), "pending");
    await relay.quiet();

    const post = await as(carol).post({ text: "Report me" });
    await heard();
    await as(carol).report(post, "Testing");
    assert.equal((await heard()).get("alice-phone")!.note.kind, "report", "reports are still on");
    await listen(as(alice), "alice-phone", { reports: false });
    await as(bob).report(post);
    await relay.quiet();
    await listen(as(alice), "alice-phone");
    await as(alice).report(post);
    await relay.quiet();
  });

  test("a relay that refuses notes changes nothing, and they aren't sent again", async () => {
    relay.status = 503;
    const lost = await as(bob).post({ text: "Lost" });
    assert.equal((await relay.next()).length, 2);
    relay.status = 200;
    const kept = await as(bob).post({ text: "Kept" });
    const notes = await heard();
    assert.deepEqual(names(notes), ["alice-phone", "frank-phone"]);
    assert.ok([...notes.values()].every((item) => item.note.post === kept));
    assert.ok((await as(alice).feed()).posts.some((item) => item.hash === lost), "the post is in");
  });

  test("a handle the relay says is gone is dropped", async () => {
    relay.gone.add(handleFor("frank-phone"));
    await as(bob).post({ text: "One" });
    assert.deepEqual(names(await heard()), ["alice-phone", "frank-phone"]);
    await as(bob).post({ text: "Two" });
    assert.deepEqual(names(await heard()), ["alice-phone"]);
    relay.gone.clear();
  });

  test("POST /me/push/test sends the asking device a test note at once, and says what the relay said", async () => {
    const phone = handleFor("alice-phone");
    assert.deepEqual(await as(alice).testPush(), { result: "sent" });
    const notes = await heard();
    assert.deepEqual(names(notes), ["alice-phone"]);
    assert.deepEqual(notes.get("alice-phone")!.note, { v: 1, kind: "test", fid: alice.fid, username: "alice", text: "", pictures: 0, post: null, thread: null });

    relay.failed.set(phone, "TopicDisallowed");
    assert.deepEqual(await as(alice).testPush(), { result: "failed", reason: "TopicDisallowed" });
    await relay.next();
    relay.failed.set(phone, "not a reason!");
    assert.deepEqual(await as(alice).testPush(), { result: "sent" }, "a reason that isn't a word is left out");
    await relay.next();
    relay.failed.clear();

    relay.status = 503;
    assert.deepEqual(await as(alice).testPush(), { result: "failed", reason: "relay-503" });
    await relay.next();
    relay.status = 200;

    relay.gone.add(phone);
    relay.failed.set(phone, "BadDeviceToken");
    assert.deepEqual(await as(alice).testPush(), { result: "gone", reason: "BadDeviceToken" });
    await relay.next();
    relay.gone.clear();
    relay.failed.clear();
    await rejects(as(alice).testPush(), 404, /nowhere/);
    await relay.quiet();
    await listen(as(alice), "alice-phone");
  });

  test("a device stops hearing when it turns notifications off, signs out, or leaves, or when it's signed out everywhere", async () => {
    await listen(as(carol), "carol-phone");
    await as(alice).removePush();
    await as(bob).post({ text: "Alice is off" });
    assert.deepEqual(names(await heard()), ["carol-phone"]);
    await listen(as(alice), "alice-phone");

    const signOut = await fixture.network.fetch("/api/v1/session", { method: "DELETE", headers: { authorization: `Bearer ${as(bob).membership.token}` } });
    assert.equal(signOut.status, 204);
    await as(alice).post({ text: "Bob signed out" });
    assert.deepEqual(names(await heard()), ["carol-phone"]);
    assert.equal(await as(bob).signIn(), "approved");
    await listen(as(bob), "bob-phone");
    await as(alice).post({ text: "Bob is back" });
    assert.deepEqual(names(await heard()), ["bob-phone", "carol-phone"]);

    await fixture.network.fetch(`/api/v1/admin/members/${bob.fid}/sign-out`, { method: "POST", headers: { authorization: `Bearer ${as(alice).membership.token}` } });
    await as(alice).post({ text: "Bob signed out everywhere" });
    assert.deepEqual(names(await heard()), ["carol-phone"]);

    await as(carol).leave();
    await as(alice).post({ text: "Carol left" });
    await relay.quiet();
  });

  test("a device whose network key was dropped for a newer one stops hearing", async () => {
    await listen(as(erin), "erin-phone", { level: "all" });
    await as(alice).post({ text: "Erin hears this" });
    assert.deepEqual(names(await heard()), ["erin-phone"]);
    // An account keeps its newest 10 network keys, so ten more from the same device drop the first.
    for (let index = 0; index < 10; index++) assert.equal(await NetworkClient.forNetwork(as(erin).identity, fixture.network.host).join(), "approved");
    await as(alice).post({ text: "Erin's first key is gone" });
    await relay.quiet();
  });
});
