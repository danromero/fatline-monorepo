/** The JSON a network server answers with. See docs/NETWORK.md. */

export type JoinStatus = "approved" | "pending" | "refused";

export interface JoinRequest {
  fid: number;
  deviceKey: string;
  deviceApproval: { issuedAt: number; signature: string };
  networkKey: string;
  networkApproval: { issued: number; signature: string };
  invite?: string;
  avatar?: string;
  push?: PushTarget;
}

/**
 * Where a device hears from a network: a relay this network lists, its handle there, the 32-byte key
 * notes are sealed with, as hex, and the time zone its twice-a-day summaries follow.
 */
export interface PushTarget {
  relay: string;
  handle: string;
  key: string;
  tz?: string;
}

/**
 * `PUT /me/push`. Unless given, a device hears new posts twice a day and replies and mentions at once,
 * and the admin also join requests and reports.
 */
export interface PushSettings extends PushTarget {
  level?: "digest" | "all" | "replies" | "off";
  requests?: boolean;
  reports?: boolean;
}

/** `POST /me/push/test`: what the relay said of the test note. */
export interface TestPushResult {
  result: "sent" | "gone" | "failed";
  /** The relay's reason, such as `BadDeviceToken`, or `relay-<status>` and `relay-unreachable`. */
  reason?: string;
}

export interface SessionRequest {
  fid: number;
  networkKey: string;
  issued: number;
  nonce: string;
  signature: string;
}

export interface Session {
  token: string;
  expires: number;
}

export interface LinkPreview {
  title?: string;
  description?: string;
  image?: string;
}

export type PostEmbed =
  | { type: "image"; url: string; width: number; height: number; src: string; full: string }
  | { type: "link"; url: string; preview: LinkPreview | null }
  | { type: "post"; hash: string; post: Post | null };

export interface Post {
  hash: string;
  fid: number;
  time: number;
  text: string;
  mentions: { fid: number; username: string }[];
  parent: string | null;
  /** Who wrote the post a reply answers, or null for a post. */
  parentFid: number | null;
  embeds: PostEmbed[];
  replies: number;
  likes: number;
  liked: boolean;
  deleted: boolean;
  /** The signed message, base64. Missing on a deleted post. */
  message?: string;
}

export interface Member {
  fid: number;
  username: string;
  displayName: string;
  bio: string;
  /** A signed link to the picture's thumb size, or null for initials. */
  avatar: string | null;
  /** Whether the picture was uploaded here, rather than copied from Farcaster. */
  ownAvatar: boolean;
  role: "admin" | "member";
  joined: number;
  muted: boolean;
}

export interface NetworkInfo {
  name: string;
  icon: string | null;
  retention: "30 days" | "forever";
  you: Member;
}

export interface FeedPage {
  posts: Post[];
  next: string | null;
}

export interface Thread {
  post: Post;
  replies: Post[];
}

/** A reply to one of your posts, or a post that mentions you. */
export interface PostActivity {
  kind: "reply" | "mention";
  post: Post;
  /** For a reply, the post it answers, with its pictures and none of its other embeds. */
  parent: Post | null;
}

/**
 * Likes on one of your posts, with `likes=1`: one item a post, placed by its newest like. Your own like
 * and likes from people you muted don't count.
 */
export interface LikeActivity {
  kind: "like";
  /** The post that was liked, one of yours. */
  post: Post;
  /** For a reply, the post it answers, with its pictures and none of its other embeds. */
  parent: Post | null;
  /** The newest likers, newest first, up to 3. */
  likers: { fid: number; username: string }[];
  /** How many people liked it. */
  count: number;
  /** When the newest like was made. */
  time: number;
}

export type ActivityItem = PostActivity | LikeActivity;

export interface ActivityPage {
  items: ActivityItem[];
  next: string | null;
}

export interface UploadedImage {
  id: string;
  url: string;
  width: number;
  height: number;
}

export interface ProfileChange {
  displayName?: string;
  bio?: string;
  /** An uploaded image's ID, or "farcaster" for the Farcaster picture. */
  avatar?: string;
  /** The Farcaster picture, which the app uploaded itself, so the network needn't fetch it. */
  farcasterPicture?: string;
}

/** A link's preview, which the post's author's app read from the page and sends. */
export interface LinkPreview {
  url: string;
  title?: string;
  description?: string;
  /** An uploaded image's ID. */
  image?: string;
}
