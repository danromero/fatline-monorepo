import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { newPerson } from "../client/local.ts";
import type { Person } from "../client/local.ts";
import type { ActivityItem } from "../src/protocol/api.ts";
import { makeLike, makePost } from "../src/protocol/messages.ts";
import type { Draft, PostRef } from "../src/protocol/messages.ts";
import { alice, bob, carol, erin, frank, handles, now, useCabin } from "./fixtures.ts";

/** Activity, and likes in it when an app asks. Against the real Worker on a local D1, with a network of this file's own. */

const fixture = useCabin();
const { as, joined } = fixture;

// Messages are signed with times from here on, a second apart where order matters, so each test's
// items come in a known order without waiting. The server takes times up to a day old.
const start = now() - 20 * 60 * 60;
const at = (second: number) => new Date((start + second) * 1000);
const post = (person: Person, draft: Draft, second: number) =>
  makePost(person.fid, draft, as(person).membership.networkKey, at(second)).then((message) => as(person).submit(message));
const like = (person: Person, target: PostRef, second: number) =>
  makeLike(person.fid, target, as(person).membership.networkKey, at(second)).then((message) => as(person).submit(message));

const withLikes = (person: Person, cursor?: string) => as(person).activity(cursor, { likes: true });
/** Each item as [kind, post], and for a like its count and likers' names. */
const summary = (items: ActivityItem[]) =>
  items.map((item) => (item.kind === "like" ? [item.kind, item.post.hash, item.count, item.likers.map((liker) => liker.username)] : [item.kind, item.post.hash]));

describe("likes in activity", () => {
  let first: string;

  test("three people liking a post make one item, naming the newest three", async () => {
    assert.equal(await joined(frank, (await as(alice).createInvite()).code), "approved");
    assert.equal(await as(frank).signIn(), "approved");
    first = await post(bob, { text: "Liked by many" }, 0);
    await like(alice, { fid: bob.fid, hash: first }, 1);
    await like(carol, { fid: bob.fid, hash: first }, 2);
    await like(erin, { fid: bob.fid, hash: first }, 3);
    const page = await withLikes(bob);
    assert.deepEqual(summary(page.items), [["like", first, 3, ["!1005", "carol", "alice"]]]);
    const [item] = page.items;
    assert.ok(item?.kind === "like");
    assert.equal(item.time, start + 3, "the newest like's time");
    assert.deepEqual(item.likers[0], { fid: erin.fid, username: "!1005" });
    assert.deepEqual([item.post.fid, item.post.likes, item.parent], [bob.fid, 3, null]);

    await like(frank, { fid: bob.fid, hash: first }, 4);
    assert.deepEqual(summary((await withLikes(bob)).items), [["like", first, 4, ["frank", "!1005", "carol"]]]);
  });

  test("your own likes never show", async () => {
    await like(bob, { fid: bob.fid, hash: first }, 5);
    const own = await post(bob, { text: "Only I liked this" }, 6);
    await like(bob, { fid: bob.fid, hash: own }, 7);
    const page = await withLikes(bob);
    assert.deepEqual(summary(page.items), [["like", first, 4, ["frank", "!1005", "carol"]]]);
    assert.equal(page.items[0]!.kind === "like" && page.items[0]!.time, start + 4, "your like doesn't move it up");
  });

  test("without the flag, activity is replies and mentions only, as before", async () => {
    const answer = await post(carol, { text: "Nice", parent: { fid: bob.fid, hash: first } }, 8);
    const page = await as(bob).activity();
    assert.deepEqual(page.items.map((item) => [item.kind, item.post.hash, item.parent?.hash]), [["reply", answer, first]]);
    assert.deepEqual(Object.keys(page.items[0]!), ["kind", "post", "parent"]);
    assert.deepEqual(summary((await withLikes(bob)).items), [["reply", answer], ["like", first, 4, ["frank", "!1005", "carol"]]]);
  });

  let older: string;
  let newer: string;

  test("liked posts sit among replies and mentions by their newest like", async () => {
    older = await post(carol, { text: "Older" }, 100);
    newer = await post(carol, { text: "Newer" }, 101);
    await like(alice, { fid: carol.fid, hash: older }, 102);
    const reply = await post(bob, { text: "A reply", parent: { fid: carol.fid, hash: newer } }, 103);
    const mention = await post(erin, { text: "Hi @carol", handles: await handles(as(erin)) }, 104);
    await like(frank, { fid: carol.fid, hash: newer }, 105);
    assert.deepEqual(summary((await withLikes(carol)).items), [
      ["like", newer, 1, ["frank"]], ["mention", mention], ["reply", reply], ["like", older, 1, ["alice"]],
    ]);
    // A new like on the older post brings it to the top.
    await like(erin, { fid: carol.fid, hash: older }, 106);
    assert.deepEqual(summary((await withLikes(carol)).items), [
      ["like", older, 2, ["!1005", "alice"]], ["like", newer, 1, ["frank"]], ["mention", mention], ["reply", reply],
    ]);
    const liked = (await withLikes(carol)).items.find((item) => item.kind === "like" && item.post.hash === newer);
    assert.equal(liked?.parent, null);
  });

  test("likes from people you muted don't count, and a post only they liked drops out", async () => {
    await as(carol).mute(erin.fid);
    const muted = (await withLikes(carol)).items;
    assert.deepEqual(summary(muted.filter((item) => item.kind === "like")), [["like", newer, 1, ["frank"]], ["like", older, 1, ["alice"]]]);
    const last = muted.at(-1);
    assert.equal(last?.kind === "like" && last.time, start + 102, "placed by the newest like left");
    await as(carol).mute(frank.fid);
    assert.deepEqual(summary((await withLikes(carol)).items.filter((item) => item.kind === "like")), [["like", older, 1, ["alice"]]]);
    await as(carol).unmute(erin.fid);
    await as(carol).unmute(frank.fid);
    assert.deepEqual(summary((await withLikes(carol)).items.filter((item) => item.kind === "like")), [
      ["like", older, 2, ["!1005", "alice"]], ["like", newer, 1, ["frank"]],
    ]);
  });

  test("a like taken back goes, and so does a deleted post's", async () => {
    await as(erin).unlike({ fid: carol.fid, hash: older });
    assert.deepEqual(summary((await withLikes(carol)).items.filter((item) => item.kind === "like")), [
      ["like", newer, 1, ["frank"]], ["like", older, 1, ["alice"]],
    ]);
    await as(alice).unlike({ fid: carol.fid, hash: older });
    assert.deepEqual(summary((await withLikes(carol)).items.filter((item) => item.kind === "like")), [["like", newer, 1, ["frank"]]]);
    // Newer has a reply, so deleting it leaves a placeholder, without its likes.
    await as(carol).remove(newer);
    const items = (await withLikes(carol)).items;
    assert.equal(items.filter((item) => item.kind === "like").length, 0);
    assert.ok(items.some((item) => item.kind === "reply" && item.parent?.deleted), "the reply under it stays");
  });

  test("a new like, or one taken back, makes a new tag, and the flag has a tag of its own", async () => {
    const read = (path: string, tag?: string) =>
      fixture.network.fetch(`/api/v1${path}`, { headers: { authorization: `Bearer ${as(carol).membership.token}`, ...(tag ? { "if-none-match": tag } : {}) } });
    const plain = (await read("/activity")).headers.get("etag")!;
    const fresh = await read("/activity?likes=1");
    const tag = fresh.headers.get("etag")!;
    assert.equal(fresh.status, 200);
    assert.notEqual(tag, plain);
    assert.equal((await read("/activity?likes=1", tag)).status, 304);
    assert.equal((await read("/activity?likes=1", plain)).status, 200);

    await like(bob, { fid: carol.fid, hash: older }, 200);
    const liked = await read("/activity?likes=1", tag);
    assert.equal(liked.status, 200);
    const likedTag = liked.headers.get("etag")!;
    assert.notEqual(likedTag, tag);
    assert.equal((await liked.json() as { items: ActivityItem[] }).items[0]!.kind, "like");

    await as(bob).unlike({ fid: carol.fid, hash: older });
    const unliked = await read("/activity?likes=1", likedTag);
    assert.equal(unliked.status, 200);
    assert.notEqual(unliked.headers.get("etag"), likedTag);
  });

  test("the cursor pages through liked posts, replies among them, each once, through likes in the same second", async () => {
    const otto = newPerson(1701, "otto");
    assert.equal(await joined(otto, (await as(alice).createInvite()).code), "approved");
    assert.equal(await as(otto).signIn(), "approved");
    const expected: { kind: string; hash: string; second: number }[] = [];
    for (let index = 0; index < 55; index++) {
      const hash = await post(otto, { text: `Post ${index}` }, 1000 + index);
      // Eleven likes a second, so the page ends among items of the same time, and a reply in some of those seconds.
      const second = 2000 + Math.floor(index / 11);
      await like(index % 2 ? bob : carol, { fid: otto.fid, hash }, second);
      expected.push({ kind: "like", hash, second });
      if (index % 10 === 0) expected.push({ kind: "reply", hash: await post(alice, { text: `Reply ${index}`, parent: { fid: otto.fid, hash } }, second), second });
    }
    expected.sort((a, b) => b.second - a.second || (b.hash > a.hash ? 1 : -1));
    assert.equal(expected[49]!.second, expected[50]!.second, "the first page ends inside a second");
    const page = await withLikes(otto);
    assert.equal(page.items.length, 50);
    assert.ok(page.next);
    const rest = await withLikes(otto, page.next);
    assert.equal(rest.next, null);
    assert.deepEqual([...page.items, ...rest.items].map((item) => [item.kind, item.post.hash]), expected.map((item) => [item.kind, item.hash]));
    assert.equal((await as(otto).activity()).items.length, 6, "without the flag, only the replies");
  });
});
