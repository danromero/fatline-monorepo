import { base64, json } from "./http.ts";

/**
 * Links to posts, `https://<host>/p/<hash>`. Outside the apps they show a page that opens the post in
 * Fatline. With APPLE_APP_ID set, the network also serves Apple's association file, so an app whose
 * Associated Domains name this host opens those links itself, without the page.
 */

/**
 * Tries the page's own link once as the page loads, so a browser that knows `fatline://` offers to open
 * the app at once. The button stays for the rest. It reads the link from the page, so its text is the
 * same on every page, and the one hash in the CSP allows it.
 */
export const OPEN_SCRIPT = `location.href = document.getElementById("open").href;`;

let scriptHash: Promise<string> | undefined;
function hashOfScript() {
  scriptHash ??= crypto.subtle.digest("SHA-256", new TextEncoder().encode(OPEN_SCRIPT)).then((digest) => base64(new Uint8Array(digest)));
  return scriptHash;
}

/** The page a post's link shows outside the apps. It shows nothing from the post. `hash` is checked by the route. */
export async function openPage(host: string, hash: string) {
  const link = `fatline://open?network=${encodeURIComponent(host)}&amp;post=${hash}`;
  const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex"><title>Fatline</title>
<style>
:root { color-scheme: light dark; --paper: #f6f1e6; --ink: #1f3d2b; }
@media (prefers-color-scheme: dark) { :root { --paper: #14211a; --ink: #efe8d8; } }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: var(--paper); color: var(--ink);
  font: 16px/1.4 Inter, -apple-system, system-ui, sans-serif; }
main { text-align: center; padding: 16px; }
a { display: inline-block; margin-top: 16px; padding: 10px 20px; border-radius: 999px; background: var(--ink); color: var(--paper);
  text-decoration: none; font-weight: 600; }
</style></head>
<body><main><p>This post is in a private Fatline network.</p><a id="open" href="${link}">Open in Fatline</a></main>
<script>${OPEN_SCRIPT}</script>
</body></html>`;
  return new Response(html, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "content-security-policy": `default-src 'none'; style-src 'unsafe-inline'; script-src 'sha256-${await hashOfScript()}'`,
      "x-content-type-options": "nosniff",
    },
  });
}

/** An App ID: a 10-character team ID, then the bundle ID, such as `ABCDE12345.com.example.fatline`. */
const APP_ID = /^[A-Z0-9]{10}\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*$/;

/** The App IDs in APPLE_APP_ID, separated by commas. One that isn't shaped like an App ID is left out. */
export function appleAppIDs(setting: string | undefined): string[] {
  const listed = (setting ?? "").split(",").map((id) => id.trim()).filter((id) => APP_ID.test(id));
  return [...new Set(listed)];
}

/**
 * GET /.well-known/apple-app-site-association, in Apple's current format: every listed app may open
 * `/p/*`. Apple's CDN fetches it over HTTPS with no cookies, so it reads nothing and needs no session.
 * Null, so the request ends in a 404, when APPLE_APP_ID lists no App ID.
 */
export function appSiteAssociation(env: { APPLE_APP_ID?: string }): Response | null {
  const appIDs = appleAppIDs(env.APPLE_APP_ID);
  if (!appIDs.length) return null;
  const file = { applinks: { details: [{ appIDs, components: [{ "/": "/p/*", comment: "A post's link." }] }] } };
  return json(file, 200, { "cache-control": "public, max-age=3600" });
}
