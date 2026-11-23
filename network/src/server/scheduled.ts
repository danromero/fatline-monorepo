import { deletionStatements } from "./deletion.ts";
import { collect, copyAvatar } from "./media.ts";
import type { Context } from "./env.ts";
import { hubURL, refreshFollows } from "./follows.ts";
import { custody, revokeOtherCustody, username } from "./identity.ts";
import { settings } from "./store.ts";
import { oldCounts } from "./daily.ts";
import { sendDigests } from "./push.ts";

const DAY = 24 * 60 * 60;
const RETENTION = 30 * DAY;
/**
 * Requests to other servers a run may make. Workers on the free plan get 50. Twice-a-day summaries come
 * out of it first, at most 8 calls to relays, then the daily pull of the admin's follows, a request a
 * page and at most 40, and members are checked with the rest.
 */
const FETCHES_PER_RUN = 48;
/** Checking a member: two requests to Optimism RPCs that must agree, and two to the fname server. */
const MEMBER_FETCHES = 4;
/** A member with no picture: one request to the hub for its link, and one for the picture. */
const PICTURE_FETCHES = 2;
/** So each hourly run checks the 12 members checked longest ago. That covers 288 a day, more than a network of 100 needs. */
const CHECKS_PER_RUN = FETCHES_PER_RUN / MEMBER_FETCHES;

/** Runs every hour. */
export async function hourly(context: Context) {
  await expire(context);
  const digests = await sendDigests(context).catch((error) => {
    console.error("summaries failed", String(error));
    return 0;
  });
  const pulling = await refreshFollows(context);
  await checkMembers(context, FETCHES_PER_RUN - digests - pulling);
  await context.db.batch([
    context.db.prepare("DELETE FROM used_signatures WHERE expires < ?").bind(context.now),
    context.db.prepare("DELETE FROM sessions WHERE expires < ?").bind(context.now),
    context.db.prepare("DELETE FROM admin_links WHERE expires < ?").bind(context.now),
    context.db.prepare("DELETE FROM admin_sessions WHERE expires < ?").bind(context.now),
    oldCounts(context),
    // Timestamps more than a day old are refused anyway, so two days is enough to stop a deleted post coming back.
    context.db.prepare("DELETE FROM removed WHERE removed < ?").bind(context.now - 2 * DAY),
  ]);
  await collect(context);
}

/** When retention is 30 days, deletes each post and reply 30 days after its timestamp. The pictures they used go after. */
export async function expire(context: Context) {
  if ((await settings(context)).retention !== "30 days") return;
  await context.db.batch(deletionStatements(context, "time < ?", [context.now - RETENTION]));
}

/** How long a member whose ownership check failed waits to be tried again. */
const RETRY = 3 * 60 * 60;

/**
 * Follows each member's Farcaster username, and stops accepting device keys any address but the FID's
 * owner approved: an old custody address once the FID has a new one, or one a wrong answer let in.
 * That person enters their recovery phrase again.
 *
 * Ownership and the username are separate: the fname server being down never keeps an old owner in,
 * and the last username stays until it answers. A member counts as checked only once Optimism said
 * who owns the FID. One it didn't answer for stays due, and waits RETRY to be tried again, so a few
 * that keep failing don't hold up everyone else.
 *
 * A member with no picture also gets their Farcaster one, when there's a hub to ask: one whose app
 * sent none, or whose picture couldn't be read when they joined.
 *
 * `fetches` is what the run has left for requests to other servers. Members it can't cover stay due.
 */
export async function checkMembers(context: Context, fetches = FETCHES_PER_RUN) {
  const due = await context.db
    .prepare("SELECT fid, avatar_media IS NULL AND farcaster_media IS NULL AS bare FROM members WHERE checked < ? AND check_after <= ? ORDER BY checked LIMIT ?")
    .bind(context.now - DAY, context.now, CHECKS_PER_RUN)
    .all<{ fid: number; bare: number }>();
  const hub = hubURL(context.env) !== null;
  for (const member of due.results) {
    const pictured = hub && member.bare === 1;
    fetches -= MEMBER_FETCHES + (pictured ? PICTURE_FETCHES : 0);
    if (fetches < 0) break;
    // Before the ownership check, which leaves the loop early when Optimism doesn't answer.
    if (pictured) await copyAvatar(context, member.fid).catch((error) => console.error("avatar copy failed", member.fid, String(error)));
    const [owner, name] = await Promise.allSettled([custody(context.env, member.fid), username(context.env, member.fid)]);
    try {
      if (owner.status === "rejected") {
        // Optimism didn't answer, or its RPCs disagreed: nothing is known, so nothing changes.
        await context.db.prepare("UPDATE members SET check_after = ? WHERE fid = ?").bind(context.now + RETRY, member.fid).run();
        continue;
      }
      const statements = [
        name.status === "fulfilled"
          ? context.db.prepare("UPDATE members SET username = ?, checked = ?, check_after = 0 WHERE fid = ?").bind(name.value, context.now, member.fid)
          : context.db.prepare("UPDATE members SET checked = ?, check_after = 0 WHERE fid = ?").bind(context.now, member.fid),
      ];
      // Every time, not only when the owner changed: a device key a wrong answer let in has the wrong
      // custody even while the member's own is right.
      if (owner.value) statements.push(...revokeOtherCustody(context, member.fid, owner.value));
      await context.db.batch(statements);
    } catch (error) {
      // The database didn't take it. This member stays due, and the next run tries again.
      console.error("member check failed", member.fid, String(error));
    }
  }
}
