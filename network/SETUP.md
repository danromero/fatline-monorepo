# Set up a Fatline network

Instructions for a coding agent. Deploy this folder to the user's Cloudflare account as their own private network, check it, and hand them its address.

A Fatline network is a small private social network on one server. People join with their Farcaster account, the admin decides who gets in, and posts never reach Farcaster. The server is a Cloudflare Worker with a D1 database and an R2 bucket for images. [docs/NETWORK.md](../docs/NETWORK.md) is the full spec, and [README.md](README.md) covers running it locally.

This guide follows `wrangler.jsonc`, `src/server/env.ts`, and `check.sh` in this folder. If they disagree with it, they're right.

## Rules

- **Never ask for a Farcaster recovery phrase.** The server never needs one. The user types theirs into the Fatline app only.
- **Keep keys out of chat, files, and the repository.** The one optional key here is typed by the user at a hidden prompt.
- **Ask before anything that could cost money:** adding R2 to the account, a paid Workers plan, or a domain.
- **Ask before replacing or deleting anything** already on the account, such as a Worker, database, or bucket with the same name.
- **Tell the user what running it means:** whoever runs the server can read everything posted there. Nothing is encrypted between members.

## Ask the user first

1. **Their FID,** the number of the Farcaster account that will run the network. If they only know the username, look it up. `.transfer.to` is the FID:

   ```bash
   curl -sS "https://fnames.farcaster.xyz/transfers/current?name=<username>" | jq .transfer.to
   ```

2. **The address.** Either the free `workers.dev` address Cloudflare gives the Worker, or a host on a domain already in their Cloudflare account, such as `social.example.com`. Settle this before anyone joins: the apps know a network by its host, and every signature names it.
3. **Who gets in.** By default, people join with an invite code, or ask and wait for the admin. Optionally, people the admin follows on Farcaster get in at once, which needs a Farcaster hub ([People you follow](#people-you-follow-get-in-at-once)).

## What it creates

| On the account | Name | Cost |
| --- | --- | --- |
| Worker | `fatline-network` | The server is written to fit the Workers free plan: 100,000 requests a day |
| D1 database | `fatline-network` | Free plan: 5 GB, 5 million rows read and 100,000 written a day |
| R2 bucket | `fatline-network-media` | The account needs R2 added first, through a checkout in the dashboard. Free up to 10 GB a month |
| Images binding | | Makes smaller sizes of each picture. 5,000 new sizes a month are free |
| Six rate limits, one hourly cron | | Free |

Nothing here has a monthly fee. The limits are Cloudflare's as of November 2026, so check its pricing pages before promising the user anything.

## Steps

You need Node.js 22.18 or later, `git`, `curl`, `jq`, and `openssl`.

### 1. Get the code

```bash
git clone --depth 1 https://github.com/danromero/fatline-monorepo.git
cd fatline-monorepo/network
npm ci
npx wrangler --version
```

The last line must print `4.156.1`, the version pinned in `package.json`. Run everything below from this `network` folder, and keep the folder afterward: its `wrangler.jsonc` is the record of this deploy.

Read `src/server/index.ts` before deploying, so you can tell the user what the server answers.

### 2. Sign in to Cloudflare

```bash
npx wrangler login
npx wrangler whoami
```

`login` opens a browser for the user to approve. Where there's no browser, have the user set `CLOUDFLARE_API_TOKEN` in the environment themselves, with a token that can edit Workers scripts, D1, and R2, plus Workers routes on the zone for a custom domain.

If `whoami` lists more than one account, ask which to use, then:

```bash
export CLOUDFLARE_ACCOUNT_ID=<account id>
```

### 3. Check the names are free

```bash
npx wrangler deployments list --name fatline-network
npx wrangler d1 list
npx wrangler r2 bucket list
```

- **Worker:** an error saying it doesn't exist means the name is free.
- **Database and bucket:** `fatline-network` and `fatline-network-media` shouldn't be listed. A deploy connects to ones that already exist instead of making new ones.
- **R2:** if `r2 bucket list` fails because R2 isn't enabled, the user adds R2 in the Cloudflare dashboard. Ask first, since the checkout may ask for a card.

If a name is taken, ask the user whether to reuse it. If not, change `name`, `database_name`, and `bucket_name` in `wrangler.jsonc`, and use the new names everywhere below.

If the account already runs a Fatline network, under any name, follow [A second network on the same account](#a-second-network-on-the-same-account) too: the six rate limits' `namespace_id` values are the same in every copy of this folder, and two Workers with the same ones share their counts.

### 4. Set the admin

In `wrangler.jsonc`, put the user's FID in `vars`, as a string:

```jsonc
"vars": {
  "ADMIN_FID": "3"
}
```

That account is let in at once, as the admin. With `ADMIN_FID` empty, nobody can approve anyone.

For an address on the user's own domain, also make the changes in [Use your own domain](#use-your-own-domain) now. To keep request logs off from the start, see [Request logs](#request-logs).

### 5. Dry run

```bash
npx wrangler deploy --dry-run
```

It should list `env.DB`, `env.MEDIA`, `env.IMAGES`, six rate limits, and `env.ADMIN_FID` with the user's FID, then exit. A warning about a module rule with no fallback is expected.

### 6. Deploy

```bash
npx wrangler deploy
```

The first deploy creates the database and bucket by the names in `wrangler.jsonc`, without asking. It prints the Worker's address, such as `https://fatline-network.<subdomain>.workers.dev`, and the hourly schedule.

- If the account has never had a Worker, Wrangler asks to register a `workers.dev` subdomain. The user chooses it.
- Wrangler may write the new database's ID into `wrangler.jsonc`. Keep that change.
- The server makes its own tables on its first request. There's no migration step.

### 7. Check it

```bash
BASE=https://fatline-network.<subdomain>.workers.dev
./check.sh "$BASE"
```

Every line should say `ok`, ending with `Everything checked out.`:

```
ok    it's a Fatline network, version 1
ok    the network itself needs a session
ok    the feed needs a session
ok    an unknown invite code is refused
ok    the admin pages need a session
```

A new address can take a minute to answer, so retry a failure before debugging it.

Plain HTTP must be refused. This prints `403`, or `301` if Cloudflare redirects first:

```bash
curl -sS -m 15 -o /dev/null -w '%{http_code}\n' "http://${BASE#https://}/api/v1/"
```

### 8. Check that it can read Farcaster's registry

Joining depends on the Worker asking Optimism who owns an FID, and `check.sh` doesn't cover that. This asks to join as the admin with a phrase made up on the spot, which must be refused:

```bash
KEYS=$(mktemp)
export FATLINE_PHRASE="$(node -e "import('viem/accounts').then(a => console.log(a.generateMnemonic(a.english)))")"
npm run --silent client -- device --keys "$KEYS" --fid <ADMIN_FID>
npm run --silent client -- join "$BASE" --keys "$KEYS"
unset FATLINE_PHRASE; rm -f "$KEYS"
```

The last command should fail with `status: 401` and `That recovery phrase doesn't own FID <ADMIN_FID>.` That's a pass: Optimism answered, and the server refused a stranger. It writes nothing to the database.

- `status: 503` means the Optimism RPCs didn't answer or disagreed. Try again in a minute, then see [Troubleshooting](#troubleshooting).
- This uses a throwaway phrase. Never put the user's own phrase in `FATLINE_PHRASE`.

### 9. The user joins as admin

This step is the user's, in the Fatline app. It needs a build with Add Network: Fatline for Mac 0.4.0 or later, or the iPhone beta. Give them the host, without `https://`:

1. On Mac, choose File, then Add Network (Shift-Command-N). On iPhone, tap the feed's title, then Add Network.
2. Enter the address and continue.
3. Enter the recovery phrase of the admin's Farcaster account, if the app asks. It asks once per device, and the phrase isn't saved.
4. The app opens the network. Nobody needs to approve the admin.

Then confirm it from your side. `members` should be 1:

```bash
npx wrangler d1 execute fatline-network --remote --command "SELECT (SELECT version FROM schema_version) AS schema, (SELECT COUNT(*) FROM members) AS members"
```

### 10. Name it and make an invite code

Also the user's. In the app, they open Settings, then Manage Network, which signs their browser in to the admin pages at `/admin`.

1. **Settings:** set the network's name, and whether posts are kept forever or for 30 days. A picture is optional.
2. **Invite codes:** choose how many people can use the code and when it expires, then Make a code. It's shown as `CODE@host`.
3. Send that whole string to a friend. They paste it into Add Network.

People who enter only the address ask to join, and wait under Requests on the admin pages.

### 11. Prove it

Reads can't prove that joining and posting work. Have the user:

1. Post with a picture.
2. Like it, then delete it.
3. Have one other person join with an invite code and reply to a post.

If all three work, the network is live. Tell the user:

- The address, and that invite codes come from the admin pages.
- Where the `network` folder is, since updates and removal run from it.
- That whoever has their Cloudflare account can read the network's posts.

## Options

Each of these is a change to `wrangler.jsonc` or a secret, followed by `npx wrangler deploy` and `./check.sh`.

### Use your own domain

The domain must be an active zone in the same Cloudflare account, and the host must have no DNS record yet. In `wrangler.jsonc`:

```jsonc
"workers_dev": false,
"preview_urls": false,
"routes": [{ "pattern": "social.example.com", "custom_domain": true }],
"vars": {
  "ADMIN_FID": "3",
  "NETWORK_HOST": "social.example.com"
}
```

- `NETWORK_HOST` is the host signatures name. It must be exactly what people type into Add Network.
- `workers_dev: false` turns off the `workers.dev` address, so the network has one address. With `NETWORK_HOST` set, joins through any other address fail.
- Cloudflare makes the DNS record and certificate. A new host can take a few minutes, and a computer that looked it up too early can keep failing for up to half an hour.

Do this before step 6 if you can. Changing the address after people have joined means each of them adds the network again.

### People you follow get in at once

Needs a Farcaster hub: any Snapchain HTTP API, such as `https://snapchain-api.neynar.com/v1` with a Neynar key.

1. Add `"HUB_URL": "https://hub.example/v1"` to `vars`.
2. If the hub needs a key, the user types it at this prompt. If you can't show them the prompt, they run it in their own terminal:

   ```bash
   npx wrangler secret put HUB_API_KEY
   ```

3. Deploy.
4. Within the hour, the network pulls who the admin follows. To have it now, the user opens the admin pages, then Settings, then Pull follows. Until the first pull, everyone still waits.

The server pulls the list from the hub once a day, and whenever the admin presses Pull follows or Pull again. People followed after a pull wait until the next one. Settings, then Joining, turns the rule off, and the daily pull with it.

With a hub, the server also asks it for each new member's Farcaster picture, once they're in, when their app sent none.

### An invite page

A page at a secret path with a Download button for the Mac app, the network's address, and a note that the admin approves requests. Set the path:

```bash
printf %s "$(openssl rand -hex 24)" | npx wrangler secret put INVITE_PATH
```

The link then appears on the admin pages under Invite codes. Anyone with it can ask to join, but nobody gets in without the admin or a code.

### Request logs

`wrangler.jsonc` turns Cloudflare's request logs on. They record each request's URL, which includes the invite page's secret path. To turn them off:

```jsonc
"observability": { "enabled": false }
```

Turn them back on while debugging.

### Other settings

| Setting | What it does |
| --- | --- |
| `OPTIMISM_RPC_URL` | Optimism RPCs, separated by commas. With two or more, an owner counts only when two agree. Defaults to five public ones |
| `MINIMUM_MAC_VERSION` | Such as `0.4.0`. Older Mac builds are told to update |
| `MEDIA_SECRET` | Signs image links. Without it, the network makes one and keeps it in its database |
| `FNAME_URL` | Defaults to Farcaster's fname server |
| `APPLE_APP_ID` | Optional, and only for apps whose Associated Domains name this network's domain. Their App IDs, such as `ABCDE12345.com.example.fatline`, separated by commas. The network then serves Apple's association file, so those apps open post links themselves |

## Updating

```bash
git pull
npm ci
npx wrangler deployments list
npx wrangler deploy
./check.sh "$BASE"
```

- Note the newest version ID from `deployments list` before deploying. `npx wrangler rollback <version id>` goes back to it.
- A rollback changes the code, not the database. New tables and columns stay.
- Your settings are local edits to `wrangler.jsonc`. If `git pull` reports a conflict there, keep your `vars`, `routes`, names, and IDs.

## Backing up

```bash
npx wrangler d1 export fatline-network --remote --output backup.sql
```

The file holds everything posted, so keep it as private as the network. It doesn't include pictures, which are in the bucket.

## A second network on the same account

Copy `wrangler.jsonc` to a new file and change `name`, `database_name`, `bucket_name`, `ADMIN_FID`, and all six `namespace_id` values. Rate limits with the same `namespace_id` share their counts across every Worker on an account. Then pass `-c <file>` to every Wrangler command.

## Removing it

This deletes every post and picture for good. Ask the user first, and offer a backup.

```bash
npx wrangler delete --dry-run
npx wrangler delete
npx wrangler d1 delete fatline-network
npx wrangler r2 bucket delete fatline-network-media
```

Cloudflare only deletes an empty bucket, so empty it first. If the dry run shows `delete` removing the database or bucket itself, skip those lines.

## Troubleshooting

`npx wrangler tail` shows the Worker's errors as they happen. Its output includes request URLs, so don't share it.

| What happens | Usual cause | Next step |
| --- | --- | --- |
| Deploy fails on R2 | R2 isn't added to the account | Step 3 |
| `check.sh` fails on its first line | Wrong address, or it isn't live yet | Wait a minute, then `curl -i "$BASE/api/v1/"` |
| Any route answers `500` | A binding is missing | Run the dry run again and compare its list with step 5 |
| The admin waits under Requests | `ADMIN_FID` is empty or isn't their FID | Fix it, deploy, and have them use Add Network again |
| The real owner's join answers `401` | `NETWORK_HOST` isn't the address they typed, or the device's clock is more than 10 minutes off | Compare the two hosts |
| A join answers `503` | The Optimism RPCs or the fname server didn't answer, or the RPCs disagreed | Retry in a minute. If it lasts, set `OPTIMISM_RPC_URL` to two or more RPCs of your own |
| A join answers `429` | More than 10 joins a minute from one address, or 30 new devices a minute for the whole network | Wait a minute |
| Uploads answer `503` | The `MEDIA` bucket binding is missing | Restore `r2_buckets` in `wrangler.jsonc` and deploy |
| Pull follows answers `502` | The hub didn't answer, or refused the key | Check `HUB_URL`, then `secret put HUB_API_KEY` again |
| `/admin` answers `401` | The admin pages open only through a one-time link | In the app: Settings, then Manage Network |
