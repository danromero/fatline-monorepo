/**
 * The statements push.ts runs to find who hears a notification, kept apart so the tests can check each
 * one's query plan in SQLite, as cost.test.ts does for the routes, whose answers can't report work done
 * behind them. Each answers a target's network key, FID, relay, handle, and key.
 */

const TARGET = "t.network_key, t.fid, t.relay, t.handle, t.key";
/** Only a member's live key hears anything. Targets go with their keys; this covers one that was missed. */
const LIVE = `EXISTS (SELECT 1 FROM network_keys n WHERE n.key = t.network_key AND n.revoked IS NULL)
  AND EXISTS (SELECT 1 FROM members me WHERE me.fid = t.fid)`;
/** A post the device `d` hasn't read, for a twice-a-day summary. */
const UNREAD = `p.parent IS NULL AND p.deleted IS NULL AND p.time > d.since AND p.fid != d.fid
  AND p.fid NOT IN (SELECT mu.muted FROM mutes mu WHERE mu.fid = d.fid)`;
/** The target's member hasn't muted the FID in `?2`. */
const NOT_MUTING = "NOT EXISTS (SELECT 1 FROM mutes mu WHERE mu.fid = t.fid AND mu.muted = ?2)";

export const PUSH_SQL = {
  /** The post's author, for a reply by `?2`. */
  reply: `SELECT ${TARGET} FROM push_targets t WHERE t.fid = ?1 AND t.level IN ('all', 'digest', 'replies') AND ${NOT_MUTING} AND ${LIVE}`,
  /** The FIDs in `?1`, a JSON array, for a mention by `?2`. */
  mention: `SELECT ${TARGET} FROM push_targets t
    WHERE t.fid IN (SELECT value FROM json_each(?1)) AND t.level IN ('all', 'digest', 'replies') AND ${NOT_MUTING} AND ${LIVE}`,
  /** Someone let in, at whatever level. */
  approved: `SELECT ${TARGET} FROM push_targets t WHERE t.fid = ?1 AND ${LIVE}`,
  /** The admin, for join requests and for reports, whomever they've muted. */
  requests: `SELECT ${TARGET} FROM push_targets t WHERE t.fid = ?1 AND t.requests = 1 AND ${LIVE}`,
  reports: `SELECT ${TARGET} FROM push_targets t WHERE t.fid = ?1 AND t.reports = 1 AND ${LIVE}`,
  /**
   * A new post by `?2` in hour `?1`, for everyone set to all posts but the FIDs in `?3`, a JSON array:
   * its author and those told of it another way. Each counts it and puts its author first among three,
   * starting again in a new hour, and answers with what it now has. SQLite reads every value in SET
   * from the row as it was, so post_hour changing doesn't change the others.
   */
  countPost: `UPDATE push_targets AS t SET
      post_count = CASE WHEN t.post_hour = ?1 THEN t.post_count + 1 ELSE 1 END,
      post_fids = CASE WHEN t.post_hour = ?1 THEN (SELECT json_group_array(value) FROM (
          SELECT value FROM (SELECT CAST(?2 AS INTEGER) AS value, -1 AS place UNION ALL SELECT value, key FROM json_each(t.post_fids) WHERE value != ?2)
          ORDER BY place LIMIT 3))
        ELSE json_array(CAST(?2 AS INTEGER)) END,
      post_hour = ?1
    WHERE t.level = 'all' AND t.fid NOT IN (SELECT value FROM json_each(?3)) AND ${NOT_MUTING} AND ${LIVE}
    RETURNING network_key, fid, relay, handle, key, post_count, post_fids`,
  /** The time zones of devices set to twice a day. */
  zones: "SELECT DISTINCT tz FROM push_targets WHERE level = 'digest'",
  /**
   * Devices set to twice a day whose slot has come: `?1` is a JSON array of [zone, its latest slot],
   * and `?2` the most to answer, those waiting longest first. CROSS JOIN reads the zones first, so
   * each is a seek in push_targets_by_digest. Each answers what it hasn't read: posts,
   * not replies, since the newer of its member's seen and when the device was added, not deleted, not
   * its member's own, and not from someone they muted. `count` stops at 999, `post` is the newest, and
   * `fids` three of their authors, most recent first.
   */
  digests: `SELECT d.network_key, d.fid, d.relay, d.handle, d.key, d.slot, d.digest_mark,
      (SELECT COUNT(*) FROM (SELECT 1 FROM posts p WHERE ${UNREAD} LIMIT 999)) AS count,
      (SELECT MAX(p.time) FROM posts p WHERE ${UNREAD}) AS newest,
      (SELECT p.hash FROM posts p WHERE ${UNREAD} ORDER BY p.time DESC, p.hash DESC LIMIT 1) AS post,
      (SELECT json_group_array(author) FROM (SELECT p.fid AS author, MAX(p.time) AS latest FROM posts p WHERE ${UNREAD}
        GROUP BY p.fid ORDER BY latest DESC LIMIT 3)) AS fids
    FROM (SELECT ${TARGET}, t.digest_mark, json_extract(j.value, '$[1]') AS slot, MAX(t.added, me.seen) AS since
      FROM json_each(?1) AS j
      CROSS JOIN push_targets t ON t.level = 'digest' AND t.tz = json_extract(j.value, '$[0]') AND t.digest_slot < json_extract(j.value, '$[1]')
      JOIN members me ON me.fid = t.fid
      WHERE EXISTS (SELECT 1 FROM network_keys n WHERE n.key = t.network_key AND n.revoked IS NULL)
      ORDER BY t.digest_slot LIMIT ?2) AS d`,
  /** What a summary of one post says: the posts whose hashes are in `?1`, a JSON array. */
  digestPosts: "SELECT hash, text, mentions, embeds FROM posts WHERE hash IN (SELECT value FROM json_each(?1))",
  /**
   * Each device in `?1`, a JSON array of [network key, slot, newest post counted], was due at that
   * slot, and its summary counted up to that post, or 0 when none went.
   */
  digested: `UPDATE push_targets SET digest_slot = json_extract(j.value, '$[1]'), digest_mark = MAX(digest_mark, json_extract(j.value, '$[2]'))
    FROM json_each(?1) AS j WHERE push_targets.network_key = json_extract(j.value, '$[0]')`,
  username: "SELECT username FROM members WHERE fid = ?",
  /** The handles in `?2`, a JSON array, that relay `?1` says Apple no longer knows. */
  gone: "DELETE FROM push_targets WHERE relay = ?1 AND handle IN (SELECT value FROM json_each(?2))",
};
