import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";
import worker from "../worker.js";

const SECRET = "a".repeat(48);
const env = { PATH_SECRET: SECRET, NEYNAR_API_KEY: "key" };
let calls;

beforeEach(() => {
  calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url, init });
    return new Response("{}", { status: 200 });
  };
});

function request(path, method = "GET", body) {
  return new Request(`https://proxy.example${path}`, { method, body, duplex: body ? "half" : undefined });
}

test("refuses to run without strong secrets", async () => {
  const configs = [
    {},
    { NEYNAR_API_KEY: "key" },
    { PATH_SECRET: SECRET },
    { PATH_SECRET: "", NEYNAR_API_KEY: "key" },
    { PATH_SECRET: "change-me", NEYNAR_API_KEY: "key" },
    { PATH_SECRET: "a".repeat(31), NEYNAR_API_KEY: "key" },
    { PATH_SECRET: `${"a".repeat(32)}/b`, NEYNAR_API_KEY: "key" },
  ];
  for (const config of configs) {
    for (const path of ["/undefined/v1/castById", "/change-me/v1/castById", `/${SECRET}/v1/castById`]) {
      const response = await worker.fetch(request(path), config);
      assert.equal(response.status, 503, `${JSON.stringify(config)} ${path}`);
    }
  }
  assert.equal(calls.length, 0);
});

test("hides everything but the allowed routes", async () => {
  const paths = [
    "/v1/castById",
    "/wrong/v1/castById",
    "/undefined/v1/castById",
    `/${SECRET}`,
    `/${SECRET}/v1/notARoute`,
    `/${SECRET}/v2/farcaster/feed/following`,
  ];
  for (const path of paths) {
    assert.equal((await worker.fetch(request(path), env)).status, 404, path);
  }
  assert.equal((await worker.fetch(request(`/${SECRET}/v1/submitMessage`), env)).status, 404);
  assert.equal(calls.length, 0);
});

test("forwards node reads with the key and the original query", async () => {
  const response = await worker.fetch(request(`/${SECRET}/v1/signersByFid?fid=1&pageSize=1`), env);
  assert.equal(response.status, 200);
  assert.equal(calls[0].url, "https://snapchain-api.neynar.com/v1/signersByFid?fid=1&pageSize=1");
  assert.equal(calls[0].init.headers["x-api-key"], "key");
  assert.equal(calls[0].init.redirect, "manual");
});

test("keeps an encoded feed cursor exactly as it arrived", async () => {
  await worker.fetch(request(`/${SECRET}/v2/farcaster/feed/following/?fid=1&cursor=a%253D`), env);
  assert.equal(calls[0].url, "https://api.neynar.com/v2/farcaster/feed/following/?fid=1&cursor=a%253D");
});

test("refuses plain HTTP without forwarding it, before anything else", async () => {
  const requests = [
    new Request(`http://proxy.example/${SECRET}/v1/castById?fid=1`),
    new Request(`http://proxy.example/${SECRET}/v1/submitMessage`, { method: "POST", body: new Uint8Array([1]), duplex: "half" }),
    new Request("http://proxy.example/wrong/v1/castById"),
  ];
  for (const plain of requests) {
    const response = await worker.fetch(plain, env);
    assert.equal(response.status, 403, plain.url);
    assert.equal(await response.text(), "This server only answers over HTTPS.");
  }
  assert.equal((await worker.fetch(new Request(`http://proxy.example/${SECRET}/v1/castById`), {})).status, 403);
  assert.equal(calls.length, 0);
});

test("still answers plain HTTP on this computer, for wrangler dev", async () => {
  for (const host of ["localhost:8787", "127.0.0.1:8787", "[::1]:8787"]) {
    const response = await worker.fetch(new Request(`http://${host}/${SECRET}/v1/castById?fid=1`), env);
    assert.equal(response.status, 200, host);
    assert.equal(response.headers.get("strict-transport-security"), null, host);
  }
  assert.equal(calls.length, 3);
});

test("adds Strict-Transport-Security over HTTPS and keeps Neynar's answer", async () => {
  globalThis.fetch = async () => new Response('{"errCode":"not_found"}', {
    status: 404,
    headers: { "content-type": "application/json", "strict-transport-security": "max-age=60" },
  });
  const forwarded = await worker.fetch(request(`/${SECRET}/v1/castById?fid=1`), env);
  assert.equal(forwarded.status, 404);
  assert.equal(forwarded.headers.get("content-type"), "application/json");
  assert.equal(forwarded.headers.get("strict-transport-security"), "max-age=31536000");
  assert.equal(await forwarded.text(), '{"errCode":"not_found"}');
  for (const [path, config, status] of [["/wrong/v1/castById", env, 404], [`/${SECRET}/v1/castById`, {}, 503]]) {
    const response = await worker.fetch(request(path), config);
    assert.equal(response.status, status, path);
    assert.equal(response.headers.get("strict-transport-security"), "max-age=31536000", path);
  }
});

test("forwards a signed message byte for byte", async () => {
  await worker.fetch(request(`/${SECRET}/v1/submitMessage`, "POST", new Uint8Array([1, 2, 3])), env);
  assert.equal(calls[0].init.method, "POST");
  assert.equal(calls[0].init.headers["content-type"], "application/octet-stream");
  const sent = new Uint8Array(await new Response(calls[0].init.body).arrayBuffer());
  assert.deepEqual([...sent], [1, 2, 3]);
});
