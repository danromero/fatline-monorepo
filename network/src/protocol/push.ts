import { MAX_CHARACTERS } from "./text.ts";

/**
 * Notification notes, as docs/NETWORK.md describes: what a note says, how it's sealed for one device,
 * and the collapse value that lets a later note replace an earlier one. The server seals; the apps
 * and the tests open.
 */

export type NoteKind = "reply" | "mention" | "post" | "approved" | "request" | "report" | "test";

export interface Note {
  v: 1;
  kind: NoteKind;
  /** Who the note is about: who replied, mentioned, posted, asked, or reported, or for `approved` and `test`, the person it's for. */
  fid: number;
  username: string;
  /** The post's text with mentions as @username, a report's note, or empty. Up to 280 characters. */
  text: string;
  /** How many pictures the post has. */
  pictures: number;
  /** The new post or reply, or the reported post. Null for `approved`, `request`, and `test`. */
  post: string | null;
  /** The top-level post it belongs to: the post itself, or the one a reply answers. */
  thread: string | null;
  /**
   * For `post` only: how many new posts this device has heard of this hour (UTC), 1 for the first. In a
   * twice-a-day summary, how many are unread.
   */
  count?: number;
  /** For `post` only: up to three of their authors, most recent first, each once. */
  usernames?: string[];
}

/** A note's JSON is at most this many bytes, so `sealed` stays under 3 KB, inside Apple's 4 KB. */
export const MAX_NOTE_BYTES = 2048;
export const KEY_BYTES = 32;
export const NONCE_BYTES = 12;

const segmenter = new Intl.Segmenter("en", { granularity: "grapheme" });
const encoder = new TextEncoder();

/**
 * The note as the bytes that get sealed: its JSON, with text cut to 280 characters, and cut further,
 * ending in "…", if the whole would be over MAX_NOTE_BYTES. Escaped control characters can make a
 * post's JSON a few times its stored size.
 */
export function noteBytes(note: Note): Uint8Array {
  let pieces = Array.from(segmenter.segment(note.text), (piece) => piece.segment);
  let cut = pieces.length > MAX_CHARACTERS;
  if (cut) pieces = pieces.slice(0, MAX_CHARACTERS - 1);
  const json = () => encoder.encode(JSON.stringify({ ...note, text: pieces.join("") + (cut ? "…" : "") }));
  let bytes = json();
  while (bytes.length > MAX_NOTE_BYTES && pieces.length > 0) {
    pieces = pieces.slice(0, -1);
    cut = true;
    bytes = json();
  }
  return bytes;
}

/** `bytes` sealed with AES-256-GCM under a device's 32-byte key: base64url(12-byte nonce ‖ ciphertext ‖ 16-byte tag). */
export async function seal(key: Uint8Array, bytes: Uint8Array, nonce: Uint8Array = crypto.getRandomValues(new Uint8Array(NONCE_BYTES))): Promise<string> {
  if (key.length !== KEY_BYTES) throw new RangeError("A push key is 32 bytes");
  if (nonce.length !== NONCE_BYTES) throw new RangeError("A nonce is 12 bytes");
  const aes = await crypto.subtle.importKey("raw", copy(key), "AES-GCM", false, ["encrypt"]);
  const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: copy(nonce) }, aes, copy(bytes)));
  const out = new Uint8Array(NONCE_BYTES + sealed.length);
  out.set(nonce);
  out.set(sealed, NONCE_BYTES);
  return base64url(out);
}

/** The bytes `seal` sealed, or null when the key is wrong or the note was changed. */
export async function open(key: Uint8Array, sealed: string): Promise<Uint8Array | null> {
  const bytes = fromBase64url(sealed);
  if (!bytes || bytes.length < NONCE_BYTES + 16 || key.length !== KEY_BYTES) return null;
  const aes = await crypto.subtle.importKey("raw", copy(key), "AES-GCM", false, ["decrypt"]);
  try {
    return new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: copy(bytes.slice(0, NONCE_BYTES)) }, aes, copy(bytes.slice(NONCE_BYTES))));
  } catch {
    return null;
  }
}

/** The hour (UTC) a time falls in, as `collapse` and a note's `count` reckon it. */
export const hourOf = (seconds: number) => Math.floor(seconds / 3600);

/**
 * The collapse value for a device's new-post notes in `hour`, or for its twice-a-day summaries with
 * `digest`: base64url of the SHA-256 of `fatline collapse`, the handle, and the hour or `digest`, on
 * three lines, 43 characters. The relay passes it to Apple as `apns-collapse-id`, so each note that
 * hour, or each summary, replaces the last. It's per handle, which is per device and network, so
 * neither Apple nor the relay can tell from it which network a note is from, or which devices share one.
 */
export async function collapseFor(handle: string, hour: number | "digest"): Promise<string> {
  return base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(`fatline collapse\n${handle}\n${hour}`))));
}

/** A copy backed by its own ArrayBuffer, as WebCrypto's types ask. */
const copy = (bytes: Uint8Array) => new Uint8Array(bytes) as Uint8Array<ArrayBuffer>;

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function fromBase64url(text: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]*$/.test(text)) return null;
  try {
    return Uint8Array.from(atob(text.replaceAll("-", "+").replaceAll("_", "/")), (character) => character.charCodeAt(0));
  } catch {
    return null;
  }
}
