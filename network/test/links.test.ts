import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { appleAppIDs, appSiteAssociation } from "../src/server/links.ts";
import { insecure } from "../src/server/transport.ts";
import { useNetwork } from "./fixtures.ts";

/** Apple's association file, which lets an app open a network's post links itself. The page's script is in pages.test.ts. */

const APP = "ABCDE12345.com.example.fatline";
const DEV = "ABCDE12345.com.example.fatline.dev";
const PATH = "/.well-known/apple-app-site-association";

const fixture = useNetwork({ APPLE_APP_ID: ` ${APP}, ${DEV} ,abcde12345.com.example.lower` });

const fileFor = (appIDs: string[]) => ({ applinks: { details: [{ appIDs, components: [{ "/": "/p/*", comment: "A post's link." }] }] } });

describe("APPLE_APP_ID", () => {
  test("takes App IDs separated by commas, once each", () => {
    assert.deepEqual(appleAppIDs(APP), [APP]);
    assert.deepEqual(appleAppIDs(` ${APP} ,${DEV},,${APP}`), [APP, DEV]);
    assert.deepEqual(appleAppIDs("ABCDE12345.app-name"), ["ABCDE12345.app-name"]);
  });

  test("leaves out anything not shaped like one", () => {
    assert.deepEqual(appleAppIDs(undefined), []);
    assert.deepEqual(appleAppIDs(" , "), []);
    for (const bad of ["abcde12345.com.example.fatline", "ABCDE1234.com.example.fatline", "ABCDE123456.com.example.fatline",
      "ABCDE12345", "ABCDE12345.", "ABCDE12345.com..fatline", "ABCDE12345.com.example.", "ABCDE12345.com.example/fatline",
      "ABCDE12345.com.exa mple", "com.example.fatline", "ABCDE12345.com.example.fatline\"]"]) {
      assert.deepEqual(appleAppIDs(bad), [], bad);
      assert.deepEqual(appleAppIDs(`${bad},${APP}`), [APP], bad);
    }
  });
});

describe("Apple's association file", () => {
  test("lets one app open /p/*", async () => {
    const response = appSiteAssociation({ APPLE_APP_ID: APP })!;
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "application/json");
    assert.deepEqual(await response.json(), fileFor([APP]));
  });

  test("lets every listed app open /p/*, in one entry", async () => {
    assert.deepEqual(await appSiteAssociation({ APPLE_APP_ID: `${APP},${DEV}` })!.json(), fileFor([APP, DEV]));
  });

  test("is missing without the setting, or with no good App ID in it", () => {
    assert.equal(appSiteAssociation({}), null);
    assert.equal(appSiteAssociation({ APPLE_APP_ID: "" }), null);
    assert.equal(appSiteAssociation({ APPLE_APP_ID: "abcde12345.com.example.fatline" }), null);
  });

  test("is served as JSON at its address, with no redirect, session, or cookie, and kept briefly", async () => {
    const response = await fixture.network.fetch(PATH, { redirect: "manual" });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "application/json");
    assert.equal(response.headers.get("cache-control"), "public, max-age=3600");
    assert.equal(response.headers.get("set-cookie"), null);
    assert.deepEqual(await response.json(), fileFor([APP, DEV]), "the lower-case team ID is left out");
    assert.equal((await fixture.network.fetch(PATH, { method: "HEAD" })).status, 200);
    assert.equal((await fixture.network.fetch(PATH, { method: "POST" })).status, 404);
    assert.equal((await fixture.network.fetch(`${PATH}.json`)).status, 404);
  });

  test("goes on over HTTPS, the only way Apple asks for it", () => {
    assert.equal(insecure(new Request(`https://friends.example.com${PATH}`)), null);
  });
});
