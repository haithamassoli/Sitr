import { test } from "node:test";
import assert from "node:assert/strict";

let loadCounter = 0;
async function loadBackground() {
  let listener;
  globalThis.chrome = { runtime: { onMessage: { addListener: (cb) => { listener = cb; } } }, downloads: { download: async () => 7 } };
  await import(`../background.js?load=${++loadCounter}`);
  return (message) => new Promise((resolve) => {
    assert.equal(listener(message, null, resolve), true);
  });
}

test("process sends a video URL through the extension worker", async () => {
  const send = await loadBackground();
  let request;
  globalThis.fetch = async (url, options) => {
    if (url.endsWith("/capabilities")) return { ok: true, json: async () => ({ product_id: "sitr-music" }) };
    request = { url, options };
    return { ok: true, json: async () => ({ job_id: "abc" }) };
  };
  assert.deepEqual(await send({ type: "process", url: "https://example.com/video", keepStems: ["vocals"] }), { ok: true, data: { job_id: "abc" } });
  assert.equal(request.url, "http://127.0.0.1:8724/process");
  assert.equal(request.options.headers["X-Sitr-Music-Client"], "extension");
  assert.deepEqual(JSON.parse(request.options.body), { url: "https://example.com/video", keep_stems: ["vocals"] });
});

test("process rejects unsupported URLs before contacting the helper", async () => {
  const send = await loadBackground();
  let called = false;
  globalThis.fetch = async () => { called = true; };
  const response = await send({ type: "process", url: "file:///private/file" });
  assert.equal(response.ok, false);
  assert.equal(called, false);
});

test("process refuses another service on the same port", async () => {
  const send = await loadBackground();
  let requests = 0;
  globalThis.fetch = async () => {
    requests++;
    return { ok: true, json: async () => ({ product_id: "nomusic" }) };
  };
  const response = await send({ type: "process", url: "https://example.com/video" });
  assert.equal(response.ok, false);
  assert.equal(requests, 1);
});

test("prioritize accepts a safe job id and chunk", async () => {
  const send = await loadBackground();
  let request;
  globalThis.fetch = async (url, options) => {
    request = { url, options };
    return { ok: true, json: async () => ({ applied: true }) };
  };
  assert.deepEqual(await send({ type: "prioritize", jobId: "abc_123", fromChunk: 2 }), { ok: true, data: { applied: true } });
  assert.equal(request.url, "http://127.0.0.1:8724/process/abc_123/prioritize");
  assert.deepEqual(JSON.parse(request.options.body), { from_chunk: 2 });
  const invalid = await send({ type: "prioritize", jobId: "../cache", fromChunk: 2 });
  assert.equal(invalid.ok, false);
});

test("cancel posts to the job's cancel route and rejects unsafe ids", async () => {
  const send = await loadBackground();
  let request;
  globalThis.fetch = async (url, options) => {
    request = { url, options };
    return { ok: true, json: async () => ({ cancelled: true }) };
  };
  assert.deepEqual(await send({ type: "cancel", jobId: "abc_123" }), { ok: true, data: { cancelled: true } });
  assert.equal(request.url, "http://127.0.0.1:8724/process/abc_123/cancel");
  assert.equal(request.options.method, "POST");
  assert.equal((await send({ type: "cancel", jobId: "../cache" })).ok, false);
});

test("worker relays status and chunk bytes without exposing localhost to pages", async () => {
  const send = await loadBackground();
  globalThis.fetch = async (url) => url.includes("/chunk/")
    ? { ok: true, arrayBuffer: async () => Uint8Array.from([1, 2, 3]).buffer }
    : { ok: true, json: async () => ({ state: "ready" }) };
  assert.deepEqual(await send({ type: "status", jobId: "abc" }), { ok: true, data: { state: "ready" } });
  assert.deepEqual(await send({ type: "chunk", jobId: "abc", index: 0 }), { ok: true, data: "AQID" });
  assert.equal((await send({ type: "chunk", jobId: "../bad", index: 0 })).ok, false);
});

test("worker starts large downloads with a guarded URL and client header", async () => {
  const send = await loadBackground();
  let options;
  chrome.downloads.download = async (value) => { options = value; return 7; };
  assert.deepEqual(await send({ type: "download", jobId: "abc", format: "mp4", height: 720, filename: "clip" }), { ok: true, data: { downloadId: 7 } });
  assert.equal(options.url, "http://127.0.0.1:8724/video/abc?max_height=720");
  assert.equal(options.filename, "clip.mp4");
  assert.deepEqual(options.headers, [{ name: "X-Sitr-Music-Client", value: "extension" }]);
  assert.equal((await send({ type: "download", jobId: "../bad", format: "mp4", height: 720 })).ok, false);
});
