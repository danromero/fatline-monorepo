import assert from "node:assert/strict";
import { before, describe, test } from "node:test";
import { newPerson } from "../client/local.ts";
import { alice, now, rejects, useCabin } from "./fixtures.ts";

/** People the admin follows, who get in without waiting once pulled. Against the real Worker on a local D1, with a network of this file's own. */

const HOUR = 60 * 60;

const fixture = useCabin({ HUB_API_KEY: "test-hub-key" });
const { as, joined, devices } = fixture;

describe("people the admin follows on Farcaster", () => {
  test("get in once the hourly job has pulled the list, with nothing pressed", async () => {
    const gus = newPerson(1907, "gus");
    fixture.network.farcaster.follow(alice.fid, gus.fid);
    assert.equal(await joined(gus), "pending", "nothing is pulled yet");
    await fixture.network.runHourly(now() + HOUR);
    assert.equal(await as(gus).signIn(), "approved");
    assert.ok(!(await as(alice).log()).some((entry) => entry.action === "pulled follows"), "only the admin's own pulls are logged");
  });

  test("wait until the next pull when followed after the last one, then get in at once, and the log says why", async () => {
    const hal = newPerson(1901, "hal");
    fixture.network.farcaster.follow(alice.fid, hal.fid);
    assert.equal(await joined(hal), "pending", "followed since the last pull");
    const pulled = await as(alice).pullFollows();
    assert.deepEqual([pulled.count, pulled.complete], [2, true]);
    assert.equal(await as(hal).signIn(), "approved");
    const hana = newPerson(1905, "hana");
    fixture.network.farcaster.follow(alice.fid, hana.fid);
    await as(alice).pullFollows();
    assert.equal(await joined(hana), "approved");
    const log = await as(alice).log();
    assert.ok(log.some((entry) => entry.action === "approved by following" && (entry.detail as { fid?: number }).fid === hana.fid));
    assert.ok(log.some((entry) => entry.action === "pulled follows"));
  });

  test("joining and signing in never ask the hub, so a waiting request can't spend its key", async () => {
    const ivy = newPerson(1902, "ivy");
    const before = fixture.network.farcaster.hubCalls;
    assert.equal(await joined(ivy), "pending");
    for (let attempt = 0; attempt < 3; attempt++) assert.equal(await as(ivy).signIn(), "pending");
    assert.equal(await (await fixture.network.device(ivy)).join(), "pending");
    assert.equal(fixture.network.farcaster.hubCalls, before);
    assert.ok(!fixture.network.farcaster.pictureAsked.includes(ivy.fid), "nor is it asked for the picture of someone who isn't in");

    // Following them later lets them in only once the admin pulls again.
    fixture.network.farcaster.follow(alice.fid, ivy.fid);
    assert.equal(await as(ivy).signIn(), "pending");
    await as(alice).pullFollows();
    assert.equal(await as(ivy).signIn(), "approved");
  });

  test("a pull takes every page, and replaces the last list", async () => {
    const many = Array.from({ length: 250 }, (_, index) => 50_000 + index);
    for (const fid of many) fixture.network.farcaster.follow(alice.fid, fid);
    fixture.network.farcaster.hubPageSize = 100;
    const before = fixture.network.farcaster.hubCalls;
    const pulled = await as(alice).pullFollows();
    fixture.network.farcaster.hubPageSize = 1000;
    assert.equal(fixture.network.farcaster.hubCalls - before, 3);
    assert.deepEqual([pulled.count, pulled.complete], [fixture.network.farcaster.follows.get(alice.fid)!.size, true]);

    // Unfollowed on Farcaster: still in the old list until the admin pulls again.
    const jay = newPerson(1903, "jay");
    fixture.network.farcaster.follow(alice.fid, jay.fid);
    await as(alice).pullFollows();
    fixture.network.farcaster.follows.get(alice.fid)!.delete(jay.fid);
    await as(alice).pullFollows();
    assert.equal(await joined(jay), "pending");
  });

  test("a hub that's down changes nothing", async () => {
    const lee = newPerson(1906, "lee");
    fixture.network.farcaster.follow(alice.fid, lee.fid);
    fixture.network.farcaster.hubDown = true;
    await rejects(as(alice).pullFollows(), 502, /didn't answer/);
    fixture.network.farcaster.hubDown = false;
    assert.equal(await joined(lee), "pending", "the failed pull kept the old list");
    await as(alice).pullFollows();
    assert.equal(await as(lee).signIn(), "approved");
  });

  test("a hub that redirects is no answer, and its key goes nowhere else", async () => {
    const farcaster = fixture.network.farcaster;
    const max = newPerson(1911, "max");
    farcaster.follow(alice.fid, max.fid);
    await as(alice).pullFollows();
    assert.equal(farcaster.lastHubKey, "test-hub-key", "the hub itself gets HUB_API_KEY");
    assert.equal(await joined(max), "approved");

    farcaster.hubRedirect = true;
    try {
      const ned = newPerson(1912, "ned");
      farcaster.follow(alice.fid, ned.fid);
      await rejects(as(alice).pullFollows(), 502, /didn't answer/);
      assert.equal(await joined(ned), "pending", "the failed pull kept the old list");
      assert.equal(await as(max).signIn(), "approved");

      // A new member's picture: the hub is asked, redirects, and the member just has none.
      const oz = newPerson(1913, "oz");
      farcaster.pictures.set(oz.fid, "https://pictures.example/test/avatar.png");
      assert.equal(await joined(oz, (await as(alice).createInvite()).code), "approved");
      for (let attempt = 0; attempt < 40 && !farcaster.redirected.includes("/hub/userDataByFid"); attempt++) await new Promise((resolve) => setTimeout(resolve, 100));
      assert.ok(farcaster.redirected.includes("/hub/linksByFid") && farcaster.redirected.includes("/hub/userDataByFid"));
      assert.equal((await as(alice).members()).find((member) => member.fid === oz.fid)?.avatar, null);
      assert.deepEqual(farcaster.elsewhere, [], "no redirect was followed");
    } finally {
      farcaster.hubRedirect = false;
    }
  });

  test("wait when the admin turns it off", async () => {
    assert.equal((await as(alice).settings()).admitFollows, true);
    assert.equal((await as(alice).updateSettings({ admitFollows: false })).admitFollows, false);
    const kim = newPerson(1904, "kim");
    fixture.network.farcaster.follow(alice.fid, kim.fid);
    await as(alice).pullFollows();
    assert.equal(await joined(kim), "pending");
    assert.equal(await as(kim).signIn(), "pending");
    await as(alice).updateSettings({ admitFollows: true });
    assert.equal(await as(kim).signIn(), "approved");
    await rejects(as(alice).updateSettings({ admitFollows: "yes" as unknown as boolean }), 400, /true or false/);
  });

  test("the hourly job pulls again once the list is a day old, and not before", async () => {
    const farcaster = fixture.network.farcaster;
    await as(alice).pullFollows();
    const mia = newPerson(1908, "mia");
    farcaster.follow(alice.fid, mia.fid);
    let calls = farcaster.hubCalls;
    await fixture.network.runHourly(now() + 23 * HOUR);
    assert.equal(farcaster.hubCalls, calls, "the list isn't a day old yet");
    assert.equal(await joined(mia), "pending");
    await fixture.network.runHourly(now() + 25 * HOUR);
    assert.equal(farcaster.hubCalls, calls + 1);
    assert.equal(await as(mia).signIn(), "approved");

    // A hub that's down keeps the list, and is asked again three hours later, not every hour.
    const noa = newPerson(1909, "noa");
    farcaster.follow(alice.fid, noa.fid);
    farcaster.hubDown = true;
    await fixture.network.runHourly(now() + 50 * HOUR);
    farcaster.hubDown = false;
    calls = farcaster.hubCalls;
    await fixture.network.runHourly(now() + 51 * HOUR);
    assert.equal(farcaster.hubCalls, calls, "it waits after a pull that failed");
    assert.equal(await joined(noa), "pending");
    await fixture.network.runHourly(now() + 54 * HOUR);
    assert.equal(farcaster.hubCalls, calls + 1);
    assert.equal(await as(noa).signIn(), "approved");

    // With the rule off, nothing uses the list, so nothing pulls it.
    await as(alice).updateSettings({ admitFollows: false });
    calls = farcaster.hubCalls;
    await fixture.network.runHourly(now() + 90 * HOUR);
    assert.equal(farcaster.hubCalls, calls);
    await as(alice).updateSettings({ admitFollows: true });
  });
});
