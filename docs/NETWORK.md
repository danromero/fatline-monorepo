# Fatline networks

A Fatline network is a small private social network on one server: everyone in it can read everyone else, and nobody outside can read anything. People join with their Farcaster account, and an admin decides who gets in. Posts never reach Farcaster.

This is version 1 of what a network server answers and how the apps sign what they send. It's written so anyone can build a client or a server against it.

Farcaster supplies identity only:

- **FID:** who owns it comes from Farcaster's ID registry on Optimism.
- **Username:** from Farcaster's fname server.
- **Avatar:** starts as the Farcaster one.

Everything else lives on the network's server.

## Addresses

A network's address is an HTTPS origin, such as `https://friends.example.com`. Its **host** is the lowercase host name and any port, with no scheme or path, as in `friends.example.com` or `friends.example.com:8443`. Signed text below names the network by its host. For local testing, apps may also accept `http://localhost`. A server answers only over HTTPS, apart from local testing: over plain HTTP it moves pages to HTTPS and refuses everything else, and over HTTPS it sends `Strict-Transport-Security`.

An invite code is written the way the apps already read codes, the code and then the host:

```
CODE@friends.example.com
```

A code is 1 to 128 characters from `A-Z a-z 0-9 - . _ ~`.

## Keys

Four things prove who someone is. Each approves the next.

| | Kept | Approved by |
| --- | --- | --- |
| Custody address | Nowhere. It comes from the recovery phrase, which is used and forgotten | Farcaster's ID registry, which says which address owns each FID |
| Device key, Ed25519 | On the device, one per device | The custody address, once per device |
| Network key, Ed25519 | On the device, one per network | The device key, when the device joins that network |
| Session token | On the device, one per network | The server, when the network key signs in |

A device key is approved once and then joins any number of networks without the recovery phrase. A network key is good only on the network its approval names, so posts can't be moved from one network to another.

### Device key approval

The custody address signs EIP-712 typed data:

```js
domain: { name: "Fatline", version: "1" }
types: {
  DeviceKey: [
    { name: "fid", type: "uint256" },
    { name: "key", type: "bytes" },      // the 32-byte Ed25519 public key
    { name: "issuedAt", type: "uint256" } // Unix seconds
  ]
}
primaryType: "DeviceKey"
```

The signature is 65 bytes, `r`, `s`, then `v` as 27 or 28, written as 0x-prefixed hex.

A server recovers the signing address and accepts the approval only if Farcaster's ID registry on Optimism, `0x00000000Fc6c5F01Fc30151999387Bb99A9f489b`, returns that address from `custodyOf(fid)`. Farcaster doesn't accept this signature as a key of its own, because both the domain and the type are Fatline's.

A server should take the owner only when two independent sources agree, so one wrong or lagging answer can't let anyone in.

When an FID's custody address changes, a server stops accepting device keys the old address approved, as soon as it sees the new owner: when a device the new owner approved joins, or at the daily check. Their network keys, sessions, and admin page sign-ins end with them, and so do keys kept for a request still waiting, which takes the new owner, so approving it lets in only theirs. The daily check also stops device keys any address but the owner approved, so a key let in on a wrong answer goes then too. It doesn't wait on the fname server: a member is checked once Optimism answers, and keeps their last username until the fname server does. Someone let in on an owner read earlier, such as a waiting request the admin approves, is checked within the hour. The person enters their recovery phrase again.

### Network key approval

The device key signs these UTF-8 bytes with Ed25519. Lines end in `\n`, and there's none after the last line:

```
Fatline network key
network: friends.example.com
fid: 3
key: 0x<the network key, 64 lowercase hex digits>
issued: 1762876800
```

`issued` is Unix seconds. A server accepts an approval issued no more than 10 minutes from its own clock.

### Signing in

The network key signs these bytes the same way:

```
Fatline session
network: friends.example.com
fid: 3
issued: 1762876800
nonce: 0x<16 random bytes, 32 lowercase hex digits>
```

The nonce means no two sign-ins sign the same text. A server accepts each signature once, within 5 minutes of `issued`.

## Messages

Posts, replies, likes, and deletions are Farcaster messages. They use the protobuf schema, BLAKE3 hash, and Ed25519 signature that Farcaster uses, encoded the way the Fatline apps already encode casts, with two differences:

- **The `network` field is left out.** It's 0, which no Farcaster node accepts, so a network's posts can't be published on Farcaster.
- **The signer is a network key.** Farcaster has never seen that key.

### The message

| Field | Value |
| --- | --- |
| `data` (1) and `data_bytes` (7) | The same `MessageData` bytes in both |
| `hash` (2) | The first 20 bytes of the BLAKE3 hash of those bytes |
| `hash_scheme` (3) | 1, BLAKE3 |
| `signature` (4) | Ed25519 over the 20-byte hash |
| `signature_scheme` (5) | 1, Ed25519 |
| `signer` (6) | The network key |

`MessageData` holds `type` (1), `fid` (2), `timestamp` (3) in seconds since January 1, 2021 UTC, no `network` (4), and one body.

### Types

| Type | Body | Rules |
| --- | --- | --- |
| `CAST_ADD` (1) | `cast_add_body` (5) | A post or a reply. See below |
| `CAST_REMOVE` (2) | `cast_remove_body` (6), `target_hash` (1) | Deletes one of your own posts or replies |
| `REACTION_ADD` (3) | `reaction_body` (7) with `type` (1) = 1, like, and `target_cast_id` (2) | Likes a post or reply on this network |
| `REACTION_REMOVE` (4) | The same | Takes a like back |

A server refuses any other type and any field not listed here.

### Posts and replies

In `cast_add_body`:

| Field | Rule |
| --- | --- |
| `text` (4) | Up to 280 characters as a person sees them, counted as grapheme clusters with each mention shown as `@username`, and up to 1,024 bytes. It can be empty only when there's an embed. It can't have characters that reverse the text around them (U+202A to U+202E and U+2066 to U+2069), tags outside a flag emoji, or variation selectors with nothing before them to vary |
| `mentions` (2) and `mentions_positions` (5) | Up to 10, as Farcaster writes them: each name leaves the text, and its FID and byte offset are kept. Only members can be mentioned |
| `embeds` (6) | Up to 2, in any mix: a `url` (1) or a `cast_id` (2). See below |
| `parent_cast_id` (3) | Present for a reply. It must name a top-level post on this network, because replies are one level deep |
| `parent_url` (7), `type` (8) | Not used |

An embed is one of three things:

- **An image:** a `url` of the form `https://<host>/m/<id>`, for an image the same person uploaded to this network.
- **A link:** any other `https` URL, up to 256 bytes, with none of the characters display names can't have.
- **A quote:** a `cast_id` naming a post on this network.

Links in the text can be tapped in the apps, whether or not they're also embeds.

### Time

A server accepts a timestamp from 24 hours before its own clock to 10 minutes after it, so an app can resend the same bytes after a send it isn't sure of.

### Sending the same message again

Sending bytes the server already has answers as if they were new. A deleted post's hash can't be added again.

## Deleting

| What happens | Effect |
| --- | --- |
| Someone deletes a post | It goes, along with its likes and any images only it used. If it has replies, it stays as a placeholder with no content, and the replies stay under it |
| Someone deletes a reply | It goes, with its likes |
| The admin removes someone, or they leave | Their posts, replies, likes, and images go, and so do their keys and sessions. Placeholders stay where others replied |
| Retention is set to 30 days | Each post or reply is deleted 30 days after its timestamp, by the same rules |

A placeholder goes once its last reply does.

## API

Everything is JSON under `https://<host>/api/v1`, except the bodies of `POST /messages` and `POST /media`. Requests carry `Authorization: Bearer <token>`, except where a route says anyone can call it. Hashes and keys are 0x-prefixed lowercase hex, and times are Unix seconds.

### Anyone

| Route | Body | Answer |
| --- | --- | --- |
| `GET /` | | `{ "fatline": "network", "version": 1 }` and nothing else about the network |
| `GET /invites/{code}` | | `{ "name", "icon" }` if the code is valid, otherwise `404` |
| `POST /join` | See below | `{ "status": "approved" }`, `"pending"`, or `"refused"` |
| `POST /session` | `{ "fid", "networkKey", "issued", "nonce", "signature" }` | See below |

A join request:

```json
{
  "fid": 3,
  "deviceKey": "0x…",
  "deviceApproval": { "issuedAt": 1762876800, "signature": "0x…" },
  "networkKey": "0x…",
  "networkApproval": { "issued": 1762876800, "signature": "0x…" },
  "invite": "CODE",
  "avatar": "https://…",
  "push": { "relay": "https://push.fatline.tech", "handle": "…", "key": "0x…" }
}
```

`invite`, `avatar`, and `push` are optional. `push` is where this device hears from the network ([Notifications](#notifications)); a waiting request has no session, so this is how it hears it's in. `avatar` is a link to the member's Farcaster picture, which the server copies in; an app that uploads that picture itself leaves it out and sends `farcasterPicture` to `PATCH /me` once signed in. Without `avatar`, a server that has a Farcaster hub (`HUB_URL`) asks it for the member's picture once they're in, and copies that in. It asks again at the daily check for a member who still has no picture. A valid invite approves the request at once and spends one of its uses. Without one, the request waits for the admin, unless the server has a Farcaster hub (`HUB_URL`) and the FID is on the admin's follow list. Then it's approved at once, which the admin can turn off in Settings (`admitFollows`). The server pulls the list from the hub once a day while that's on, and when the admin asks (`POST /admin/follows/pull`, or Pull follows on Settings). Joins and sign-ins check that kept list, never the hub. A waiting request is checked again at each `POST /session`, so someone the admin follows later gets in after the next pull. Asking again while a request waits changes nothing, and asking again after the admin refused stays refused. A member's new device is approved at once.

`avatar` is the Farcaster picture as the app knows it. A server that can read Farcaster profiles itself uses its own copy instead. Either way, the server copies the picture into its own storage.

`POST /session` answers one of:

| Status | Answer | Meaning |
| --- | --- | --- |
| `200` | `{ "token", "expires" }` | Signed in. The token lasts 30 days, and signing in again before then gets a new one |
| `202` | `{ "status": "pending" }` | The admin hasn't decided yet |
| `403` | `{ "status": "refused" }` | Refused, removed, or blocked, or this device was signed out everywhere. A device that was signed out joins again only with a new device key, from the recovery phrase |

### Members

| Route | Answer |
| --- | --- |
| `GET /network` | `{ "name", "icon", "retention": "30 days" or "forever", "you": Member }` |
| `GET /feed?cursor=&replies=1` | `{ "posts": [Post], "next" }`. Top-level posts, newest first, 50 to a page, without people you muted. Deleted posts stay out, even with replies. With `replies=1`, replies are in it too, among the posts by time, except replies to someone you muted; each has the post it answers in `parent` and that post's author in `parentFid`. An app asks for them once it shows whom a reply answers. Supports `If-None-Match` |
| `GET /posts/{hash}?cursor=` | `{ "post": Post, "replies": [Post], "next" }`, with the newest 200 replies first, oldest first within the page; `next` is the cursor for older ones, or null. Supports `If-None-Match` |
| `POST /messages` | Body: the message bytes, as `application/octet-stream`. Answers `{ "hash" }`. An app that reads its links' pages itself sends `Fatline-Previews: app`, and the server then reads none of them |
| `PUT /posts/{hash}/previews` | `{ "previews": [{ "url", "title", "description", "image" }] }`, one for each of the post's links at most, from its author only. `url` is one of the post's own links; `title` and `description` are up to 300 characters, on one line, and can't hide or reverse text; `image` is an uploaded image's ID. Each replaces that link's last. Answers `204` |
| `POST /media` | Body: one JPEG, PNG, or GIF, up to 10 MB and 4,096 pixels on a side, sent with its own `Content-Type`. A GIF, which is never resized, can be at most 1,280 pixels on a side, with at most 50 million pixels across all its frames. Answers `{ "id", "url", "width", "height" }`. The server takes out EXIF, XMP, and comments from a JPEG, text chunks from a PNG, and comments and application blocks from a GIF, keeping only its loop count. Anything after the end of the picture goes too, such as a gain map. Apps should turn a photo upright first. An image no post or profile uses within 24 hours is deleted. A member can upload 50 a day, and more answer `429` |
| `GET /activity?cursor=&likes=1` | `{ "items": [{ "kind": "reply" or "mention", "post": Post, "parent": Post or null }], "next" }`, newest first, without people you muted. `parent` is the post a reply answers, without its embeds. With `likes=1`, likes on your posts and replies are in it too, one item a post, placed by its newest like: `{ "kind": "like", "post": Post, "parent": Post or null, "likers": [{ "fid", "username" }], "count", "time" }`. `likers` is up to 3 of the newest, newest first, `count` how many liked it, and `time` when the newest like was. Your own like and likes from people you muted don't count, and a post that's deleted, or whose likes are all taken back, drops out. An app asks for likes once it shows them. Supports `If-None-Match` |
| `GET /members` | `{ "members": [Member] }` |
| `PATCH /me` | `{ "displayName", "bio", "avatar", "farcasterPicture" }`, any of them. `avatar` is an uploaded image's ID, or `"farcaster"` for the Farcaster picture. `farcasterPicture` is an uploaded image's ID for the Farcaster picture itself, which the app uploaded so the server needn't fetch it. Display names are up to 32 characters and bios up to 160. Neither can have control characters, bidi controls, or characters that show as nothing, though a bio can break lines. Zero-width joiners are fine, since emoji need them |
| `PUT /mutes/{fid}`, `DELETE /mutes/{fid}` | `204` |
| `POST /reports` | `{ "post", "note" }`, with a note of up to 280 characters. `204` |
| `POST /leave` | `204`. Deletes everything of yours, as removal does. You can ask to join again. The person who runs the network can't leave it |
| `PUT /me/push`, `DELETE /me/push` | `204`. Where and what this device hears. See [Notifications](#notifications) |
| `POST /me/push/test` | `200 { "result", "reason"? }`. A test notification to this device, from Debug. See [Notifications](#notifications) |
| `DELETE /session` | `204`. Ends the token the request carries, and no other, and this device stops hearing from the network. The device keeps its keys, so it can sign in again |
| `POST /admin-link` | Admins only. `{ "url" }`, a link that signs a browser in to `/admin` once, within 60 seconds. The link and the sign-in belong to the network key that asked, and end when it does |

A Post:

```json
{
  "hash": "0x…",
  "fid": 3,
  "time": 1762876800,
  "text": "Dinner at 7? @alice",
  "mentions": [{ "fid": 12, "username": "alice" }],
  "parent": null,
  "parentFid": null,
  "embeds": [
    { "type": "image", "url": "https://host/m/ab12…", "width": 2048, "height": 1536,
      "src": "https://host/media/ab12…/display?…", "full": "https://host/media/ab12…/original?…" },
    { "type": "link", "url": "https://example.com/menu",
      "preview": { "title": "…", "description": "…", "image": "https://host/media/…" } },
    { "type": "post", "hash": "0x…", "post": "a Post without its own embeds, or null if deleted" }
  ],
  "replies": 2,
  "likes": 5,
  "liked": true,
  "deleted": false,
  "message": "the signed message bytes, base64"
}
```

`text` shows each mention as `@username`. On a reply, `parent` is the post it answers and `parentFid` that post's author; both are null on a post. A deleted post with replies comes back with `deleted: true` and no text, embeds, or message. `message` lets an app check the signature itself.

A Member:

```json
{ "fid": 3, "username": "dwr", "displayName": "Dan", "bio": "", "avatar": "https://host/media/…/thumb?…",
  "ownAvatar": false, "role": "admin", "joined": 1762876800, "muted": false }
```

### Admins

The admin is the FID the server was deployed with, read on every request: deploy with another FID and the old admin is a member at once, signed out of the admin pages. These routes answer only the admin. Each change goes in the admin log.

| Route | Body | Answer |
| --- | --- | --- |
| `GET /admin/requests` | | `{ "requests": [{ "fid", "username", "requested", "status" }] }`, waiting and refused |
| `POST /admin/requests/{fid}/approve`, `/refuse` | | `204` |
| `POST /admin/members/{fid}/remove` | | `204`. Removes them as leaving does, and blocks them from asking again |
| `POST /admin/members/{fid}/sign-out` | | `204`. Signs them out everywhere, for a lost or stolen device: their device keys and network keys stop working, and their sessions and admin page sign-ins end. Their posts stay and they aren't blocked, so they can sign in again with their recovery phrase. The admin pages have it as Sign out everywhere |
| `POST /admin/posts/{hash}/delete` | | `204`. Deletes one post or reply, as its author deleting it would: a post with replies leaves a placeholder. The admin pages have it as Delete post, under Reports |
| `GET /admin/blocks`, `DELETE /admin/blocks/{fid}` | | The blocked list, and unblocking, after which they can ask again |
| `GET /admin/invites` | | `{ "invites": [{ "code", "usesLeft", "expires", "created", "used", "revoked" }] }` |
| `POST /admin/invites` | `{ "code", "uses", "expires" }`, all optional | The new invite. One use and no expiry unless given. `uses: null` is unlimited, and the code is made up when left out. A code you choose is 8 to 128 characters |
| `DELETE /admin/invites/{code}` | | `204` |
| `GET /admin/settings`, `PATCH /admin/settings` | `{ "name", "retention" }` | `{ "name", "retention" }`. The name is up to 64 characters, and the host until set |
| `POST /admin/follows/pull` | | `{ "count", "pulled", "complete" }`. Takes everyone the admin follows from the hub and keeps that list in place of the last one, for joins to check. `complete` is false when there were more than one pull takes. A hub that fails answers `502` and changes nothing |
| `GET /admin/reports`, `POST /admin/reports/{id}/resolve` | | `{ "reports": [{ "id", "post", "postFid", "fid", "note", "created", "resolved", "here" }] }` |
| `GET /admin/log` | | `{ "entries": [{ "id", "time", "admin", "action", "detail" }] }`, newest first |

`avatar` is a link to the picture's `thumb` size, or null for initials. It's the picture the member uploaded here, or else their Farcaster picture as the server copied it in when they joined. `ownAvatar` says which.

A link embed's `preview` is what the post's author's app sent (`PUT /posts/{hash}/previews`), which is that post's alone, or else what the server read from the page when the post arrived, over HTTPS only, from public addresses, with a short timeout and a size cap. It's null until then, or if the page had nothing. Its `image` is a link to the picture's `display` size, copied into the network: up to 1 MB, and counted against the poster's 50 pictures a day, past which the preview has no picture.

### Images

Image links in answers are signed and last at least an hour, and a link stays the same for an hour at a time. Apps should cache images by ID and size, not by link. A link that has expired or been changed answers `403`.

Each size is served as AVIF or WebP when the request's `Accept` header takes them, and otherwise as JPEG, or PNG for a PNG. A GIF is served as it was uploaded at every size, so it keeps moving.

| Size | What it is |
| --- | --- |
| `display` | Up to 1,280 pixels wide |
| `thumb` | 192 pixels, for avatars and icons |
| `original` | The file as it was uploaded |

`https://<host>/m/<id>`, the address inside a signed message, serves nothing to anyone.

### The network's picture

`icon` in `GET /network` and `GET /invites/{code}` is a link to the network's picture, `https://<host>/icon?v=<version>`, or `null` when it has none. Apps show it in place of the network's first letter, filling the same rounded square. The version changes with the picture, so apps can cache it by link. Anyone can load it, without signing in, because the invite page shows it. The admin uploads it on the admin pages under Settings: a PNG, JPEG, or GIF up to 2 MB, at least 32 pixels on each side, and within the limits for uploads, kept without its metadata.

### App versions

The apps name their build in a `Fatline-App` header on every request, such as `mac/0.3.91` or `iphone/0.1.1`. A server may set a minimum Mac version (`MINIMUM_MAC_VERSION`), and then answers older Mac builds with `426` and a message asking them to update. Mac builds from before the header only identify as `Fatline/<build>` in their user agent, so they count as older than any minimum. Requests with neither are never turned away.

### Errors

Errors are JSON with a `message` the app may show, as on other Fatline servers, and a `code` an app can act on whatever the words. Most codes name the status; the rest are listed below.

| Status | Code | Meaning |
| --- | --- | --- |
| `400` | `bad-request` | Malformed, or breaks a rule above |
| `400` | `hidden-text` | Text with invisible characters, or ones that reverse text |
| `400` | `unknown-relay` | The network doesn't send notifications through that relay. Send it again without `push` |
| `401` | `signed-out` | No token, an expired one, or a signature that doesn't check out. Sign in again |
| `403` | `refused` | Not a member any more. The answer also has `{ "status": "refused" }`, which apps from before codes read |
| `403` | `forbidden` | Not allowed, such as an admin route for a member |
| `404` | `not-found` | No such thing. The admin routes say which: `no-person`, `no-request`, `no-member`, `no-code`, `no-report`, `no-post` |
| `413` | `too-large` | Too large |
| `426` | `update-required` | This build of the app is older than the network allows. The `message` says to update |
| `429` | `too-many` | Too many requests. Try again in a minute |
| `429` | `daily-limit` | Past a daily limit below. Try again tomorrow |
| `503` | `unavailable` | Optimism or Farcaster's name server didn't answer. Try again in a minute |

Besides limits a minute, by address and by member, a member's changes through the API can write 5,000 database rows a day (UTC), as D1 counts them, index entries included, so a post costs what it writes (about 10 to 20 rows), upload 50 pictures, and file 20 reports, and gets `429` past them. An account can also sign in 100 times a day and send `POST /join` 50 times. Past its sign-ins, `POST /session` writes nothing, not even the signature. Signing out, leaving, and deleting your posts don't count, so they always work. A member can make 120 reads a minute across all their devices, and a read that reads more than 100 database rows counts its rows against 200,000 a day; answers from the cache and `304`s are free. `GET /feed` and `GET /activity` answer with an `ETag`, and a request whose `If-None-Match` matches answers `304` without reading the feed, so apps should send it when they poll. An account keeps at most 10 devices on a network at once, counting those added or signed in within 30 days (the admin is never limited this way), the newest 10 network keys, and the newest 20 sessions; a device whose network key was dropped joins again with its own device key. IPv6 addresses count by their /64. A join from a new device asks Optimism who owns the FID, and the whole network asks at most 30 times a minute; past that, those joins answer `429`. Image links and the network's picture take 1,000 loads a minute per address.

## Usernames

A username is the person's fname. The server accepts it only when the fname server says it's theirs now:

- `GET https://fnames.farcaster.xyz/transfers/current?fid=<fid>` returns a transfer to that FID.
- `GET https://fnames.farcaster.xyz/transfers/current?name=<username>` returns the same FID.

The fname's `owner` can differ from the current custody address, so a server doesn't compare them.

An FID with no fname is shown as `!<fid>`, as Farcaster does. Servers check usernames again every day.

## Links to posts

A post's link is `https://<host>/p/<hash>`.

- **Inside the apps,** it opens the post on that network. As an embed, it shows as a quote.
- **Anywhere else,** the server answers with a page that says Open in Fatline and links to `fatline://open?network=<host>&post=<hash>`. The page tries that link once as it loads, and shows nothing from the post.
- **Optionally,** a server serves Apple's association file at `/.well-known/apple-app-site-association`, covering `/p/*`, so an app whose Associated Domains name its domain opens these links without the page.

## Notifications

A network tells a member's phone about new posts, twice a day by default, and about replies, mentions, and its own news as they happen, through a relay. Apple only takes pushes signed with the app's own key, and every network is a separate server, so one relay holds the key. The network seals each note for one device, and the relay passes it on without being able to read it.

```
phone ──device token──▶ relay ──handle──▶ phone                once per network
phone ──relay, handle, key, choices──▶ network                 PUT /me/push, or push in POST /join
any device ──newest post seen──▶ network                        PUT /me/seen
network ──handle, sealed note──▶ relay ──▶ Apple ──▶ phone      which opens the note
```

### Who hears what

| Event | Who hears | `kind` |
| --- | --- | --- |
| Posts they haven't read | Members set to `digest`, at 9 a.m. and 9 p.m. where each device is, if something's new | `post` |
| A new post | Members set to `all`, grouped by the hour | `post` |
| A reply | The post's author, set to `digest`, `all`, or `replies` | `reply` |
| A mention | Each member it mentions, set to `digest`, `all`, or `replies` | `mention` |
| A waiting request is let in | The person who asked, by the admin or a follow | `approved` |
| A join request | The admin, with `requests` on | `request` |
| A report | The admin, with `reports` on | `report` |

- **One note per event:** a reply that also mentions you is a `reply`, and a post that mentions you is a `mention`.
- **Never about your own post or report.** Nothing from someone you muted, except requests and reports. No likes and no refusals.
- **Only a member's live network key hears anything.** Each device has its own choices.

### Routes

| Route | Body | Answer |
| --- | --- | --- |
| `PUT /me/push` | `{ "relay", "handle", "key", "tz", "level", "requests", "reports" }` | `204`, for the network key the session signed in with |
| `DELETE /me/push` | | `204`. This device hears nothing more. Free, like signing out |
| `PUT /me/seen` | `{ "time" }` | `204`. The newest post this member has had on screen, on any device |
| `POST /me/push/test` | | `200 { "result", "reason"? }`. A `test` note to this device, sent at once. `404` with `no-push` when this network has nowhere to send it |
| `POST /join` | Gains an optional `push: { "relay", "handle", "key", "tz" }` | As above |

- **`relay`** is one the network lists (`PUSH_RELAYS`, by default `https://push.fatline.tech`), compared without a trailing slash. Any other answers `400` with `unknown-relay`, so nobody can point the server at an address of their choosing. A join answered that way changed nothing, so the app sends it again without `push`.
- **`handle`** is the device's handle at that relay, 16 random bytes as 22 base64url characters. **`key`** is a random 32-byte key the device made for this network, as hex.
- **`tz`** is where the device is, as a time zone's name such as `America/New_York`, for when its summaries go. Left out, it stays as it was, or UTC for a new device. One the server's clock doesn't know is UTC; one that isn't a zone's name at all answers `400`.
- **`level`** is `digest` (new posts in a summary twice a day, replies and mentions at once), `all` (each new post, replies, and mentions), `replies` (replies and mentions), or `off`, and `digest` when left out. `requests` and `reports` are the admin's own switches, on unless `false`, whatever the level. To hear nothing at all, `DELETE /me/push`.
- **`time`** in `PUT /me/seen` is a post's `time`, in seconds: the newest post the member has had on screen. Seen belongs to the member, not the device, so reading on one leaves it out of every device's summary. It only moves forward, and never past now.
- **A join's `push`** gives a new device `digest` and keeps what a known one chose. Sending the join again with `push` while the request waits adds it, for an app that asks the person after Request sent.
- **A handle belongs to one network key.** Putting it on another takes it off the first.
- **`POST /me/push/test`** goes to the device whose network key asks, at once rather than behind the answer, and says what the relay said: `result` is `sent` (the relay passed it to Apple), `gone` (the relay or Apple no longer knows the device, so the network forgot it), or `failed`. `reason` is the relay's (`failed` in its answer, such as `BadDeviceToken` or `hourly-limit`), or `relay-<status>` and `relay-unreachable`; a relay that gives none leaves it out, or says `unknown-handle` for a gone handle. 20 a day per member, and the per-minute limit posting has.
- **A device stops hearing when its network key goes:** it leaves or is removed, it's signed out everywhere, it sends `DELETE /session`, its key is older than the account's newest 10, or the FID gets a new owner. A handle the relay says is gone goes too.

### Sending

- **After the change is written,** behind the answer, the network sends `POST <relay>/send` with `{ "notes": [{ "handle", "sealed", "collapse" }] }`, at most 40 to a call. Only new posts and summaries have `collapse`.
- **Summaries go from the hourly job,** ahead of its other work, at most 8 relay calls a run, so 320 devices an hour. A device past that waits for the next run.
- **The relay answers `{ "gone": [handle] }`,** the handles Apple no longer knows, and the network forgets them.
- **Nothing is tried again.** A lost note is a missed notification, never a lost post.
- **A new post costs what it writes:** it counts a database row for each device it reaches against its author's 5,000 a day.

### The note

```json
{ "v": 1, "kind": "post", "fid": 3, "username": "mika", "text": "Hike at 9? @sana", "pictures": 0,
  "post": "0x…", "thread": "0x…", "count": 3, "usernames": ["mika", "sana", "dave"] }
```

| Field | Value |
| --- | --- |
| `v` | `1` |
| `kind` | `post`, `reply`, `mention`, `approved`, `request`, `report`, or `test` |
| `fid`, `username` | Who posted, replied, mentioned, asked, or reported. For `approved`, the person let in, and for `test`, the person who asked |
| `text` | The post's text with mentions as `@username`, a report's note, or empty. Up to 280 characters, and cut shorter, ending in `…`, only if the note would pass 2,048 bytes |
| `pictures` | How many pictures the post has |
| `post` | The new post or reply, or the reported post. `null` for `approved`, `request`, and `test` |
| `thread` | The top-level post: the post itself, or the one a reply answers. `null` for `approved`, `request`, and `test` |
| `count` | `post` only. How many new posts this device has heard of this hour (UTC), this one included. In a summary, how many it hasn't read, up to 999 |
| `usernames` | `post` only. Up to three of their authors, most recent first, each once |

In a summary, `post`, `thread`, `fid`, and `username` are the newest unread post's, and `text` and `pictures` are only filled when `count` is 1.

The app writes the words from these, such as "37 Club: 3 new posts from mika, sana, and dave", with the network's name as the phone saved it at join, never a name from the note.

### Sealing

- **AES-256-GCM** under the device's key, over the note's UTF-8 JSON, with a random 12-byte nonce and no associated data.
- **`sealed`** is base64url, without padding, of the nonce, the ciphertext, and the 16-byte tag. A note is at most 2,048 bytes, so `sealed` stays under 3 KB, inside Apple's 4 KB.
- **Test vectors** (key, nonce, plaintext, sealed) are in [network/test/push-vectors.json](../network/test/push-vectors.json).

### Twice a day

A device set to `digest` hears, at 9 a.m. and 9 p.m. on its own clock (`tz`), how many posts its member hasn't read:

- **Unread** is a post, not a reply, newer than both the member's seen and when the device first gave the network its push, not deleted, not the member's own, and not from someone they muted. Counted as the summary goes, so a post deleted since doesn't count.
- **Only when something's new** since the device's last summary. Nothing new, nothing sent, even with posts still unread.
- **One a slot.** A run of the hourly job that's late or missed catches up on the next, with one summary, not one per slot missed.
- **Each replaces the last** still showing, through `collapse` (below).

### Grouping new posts

New posts within a clock hour (UTC) show as one notification per network that updates in place. Each new-post note carries `collapse`, which the relay passes to Apple as `apns-collapse-id`, so the next note with the same value replaces the last. It's base64url of the SHA-256 of these UTF-8 bytes, 43 characters:

```
fatline collapse
<handle>
<the hour: Unix seconds divided by 3,600, rounded down>
```

A summary's `collapse` is the same with `digest` in place of the hour, so each summary replaces the device's last.

It's per handle, which is per device and network, so neither the relay nor Apple can tell from it which network a note came from, or which devices share one.

### What each side sees

| Who | Sees | Never sees |
| --- | --- | --- |
| The network | What it already sees, each device's relay, handle, key, and time zone, and the newest post each member has seen | The device token |
| The relay | The handle, the device token, the sending domain, the time, the note's size, `collapse` | Names, words, which post, the key |
| Apple | The device token, the handle, the time, the note's size, `collapse` | Names, words, which network |

## What the admin can and can't do

The server sees everything posted on it. Nothing is encrypted between members.

**The Fatline apps don't check signatures yet.** Until they do, the server, or anyone with its database, can forge posts and likes for any member, and the apps will show them. The server checks every message it receives, but nothing checks the server.

Once the apps check them, signatures stop the server, or anyone with its database, from inventing a post or changing one:

- **For each post,** an app checks the hash and the signature.
- **For each network key,** once, it checks the key's approval by the device key, the device key's approval by the custody address, and, from Optimism directly, that the custody address owns the FID.

Signatures don't stop the server from hiding or deleting posts.
