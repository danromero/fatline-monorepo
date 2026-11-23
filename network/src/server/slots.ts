/**
 * When twice-a-day summaries go: 9 a.m. and 9 p.m. on the clock where each device is. A slot is the
 * moment, in Unix seconds, so devices in different zones compare by one number.
 */

/** The local hours a summary goes at. */
export const DIGEST_HOURS = [9, 21];

/** Every zone in use today is a whole number of quarter hours off UTC, so slots fall on a quarter hour. */
const STEP = 15 * 60;
/** Slots are 11 to 13 hours apart, across a change to or from summer time. */
const LONGEST_GAP = 13 * 60 * 60;
/** A time zone's name, such as America/New_York, as an app sends it. */
const ZONE = /^[A-Za-z][A-Za-z0-9_+/-]{0,63}$/;

const clocks = new Map<string, Intl.DateTimeFormat>();

/** `zone` if the runtime knows it, or null. */
export function knownZone(zone: string): string | null {
  if (!ZONE.test(zone)) return null;
  try {
    clock(zone);
    return zone;
  } catch {
    return null;
  }
}

function clock(zone: string) {
  let format = clocks.get(zone);
  if (!format) {
    format = new Intl.DateTimeFormat("en-US", { timeZone: zone, hour: "numeric", minute: "numeric", hourCycle: "h23" });
    clocks.set(zone, format);
  }
  return format;
}

function isSlot(zone: string, seconds: number) {
  let hour = -1;
  let minute = -1;
  for (const part of clock(zone).formatToParts(seconds * 1000)) {
    if (part.type === "hour") hour = Number(part.value);
    if (part.type === "minute") minute = Number(part.value);
  }
  return minute === 0 && DIGEST_HOURS.includes(hour);
}

/** The latest slot in `zone` at or before `now`. */
export function lastSlot(zone: string, now: number): number {
  for (let at = Math.floor(now / STEP) * STEP; at >= now - LONGEST_GAP; at -= STEP) {
    if (isSlot(zone, at)) return at;
  }
  // Not for a real zone. The slot then never moves, so the device just hears no summaries.
  return 0;
}

/** The first slot in `zone` after `now`. For tests and the demo. */
export function nextSlot(zone: string, now: number): number {
  for (let at = (Math.floor(now / STEP) + 1) * STEP; at <= now + LONGEST_GAP + STEP; at += STEP) {
    if (isSlot(zone, at)) return at;
  }
  return Infinity;
}
