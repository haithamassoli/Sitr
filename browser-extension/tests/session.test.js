// Unit tests for session.js — the chunk-index math and buffer check, which
// drive seek handling and pause/resume. Instantiated with plain stand-ins for
// the <video> and Button (the constructor touches no browser APIs).
import { test } from "node:test";
import assert from "node:assert/strict";

import { Session, resolveSourceUrl, normalizeWatchUrl } from "../session.js";

// Run `fn` with a mocked MAIN-world bridge: dispatching the resolve event makes
// `document` answer with `bridgeUrl` on the documentElement attribute, exactly
// as page-script.js does in the browser. Restores globals afterwards.
function withBridge(bridgeUrl, fn) {
  const root = {
    a: {},
    setAttribute(k, v) {
      this.a[k] = v;
    },
    getAttribute(k) {
      return k in this.a ? this.a[k] : null;
    },
    removeAttribute(k) {
      delete this.a[k];
    },
  };
  const prevDoc = globalThis.document;
  const prevCE = globalThis.CustomEvent;
  globalThis.CustomEvent = class {
    constructor(type) {
      this.type = type;
    }
  };
  globalThis.document = {
    documentElement: root,
    dispatchEvent() {
      root.setAttribute("data-nomusic-source-url", bridgeUrl);
    },
  };
  try {
    return fn();
  } finally {
    globalThis.document = prevDoc;
    globalThis.CustomEvent = prevCE;
  }
}

function makeSession() {
  const s = new Session(/* video */ {}, /* button */ {});
  // Mirror the backend defaults the session starts with (config.py).
  s.chunkSeconds = 10;
  s.chunkOverlapSeconds = 0.5; // stride = 9.5s
  return s;
}

test("_chunkIdxForTime maps a time to its chunk via the stride", () => {
  const s = makeSession();
  assert.equal(s._chunkIdxForTime(0), 0);
  assert.equal(s._chunkIdxForTime(9.4), 0);
  assert.equal(s._chunkIdxForTime(9.5), 1); // first instant of chunk 1
  assert.equal(s._chunkIdxForTime(19.0), 2);
});

test("_chunkIdxForTime never returns a negative index", () => {
  const s = makeSession();
  assert.equal(s._chunkIdxForTime(-5), 0);
});

test("_isBuffered reflects whether the covering chunk is decoded", () => {
  const s = makeSession();
  assert.equal(s._isBuffered(9.5), false);
  s.chunks.set(1, { buffer: {}, playStart: 9.5 });
  assert.equal(s._isBuffered(9.5), true); // time 9.5 -> chunk 1
  assert.equal(s._isBuffered(0), false); // time 0 -> chunk 0, not buffered
});

test("a different stride shifts the chunk boundaries", () => {
  const s = makeSession();
  s.chunkSeconds = 30;
  s.chunkOverlapSeconds = 1; // stride = 29s
  assert.equal(s._chunkIdxForTime(28.9), 0);
  assert.equal(s._chunkIdxForTime(29.0), 1);
});

test("requestJob posts the captured sourceUrl, not the live page URL", async () => {
  const s = makeSession();
  s.sourceUrl = "https://orig.example/watch?v=A"; // captured at start()
  const previous = chrome.runtime.sendMessage;
  let capturedMessage = null;
  chrome.runtime.sendMessage = async (message) => {
    capturedMessage = message;
    return { ok: true, data: { job_id: "J", total_chunks: 3 } };
  };
  try {
    const info = await s.requestJob();
    assert.equal(capturedMessage.url, "https://orig.example/watch?v=A");
    assert.equal(capturedMessage.type, "process");
    assert.equal(info.job_id, "J");
  } finally {
    chrome.runtime.sendMessage = previous;
  }
});

test("_resumeProcessing adopts a changed job_id and refetches chunks", async () => {
  const s = makeSession();
  s.jobId = "OLD";
  s.fetchedIdx = new Set([0, 1, 2]);
  let closed = false;
  s.eventSource = {
    close() {
      closed = true;
    },
  };
  s.requestJob = async () => ({ job_id: "NEW", total_chunks: 5 });
  let opened = 0;
  s._openEventStream = () => {
    opened++;
  };
  s._sendPrioritizeHint = () => {};

  await s._resumeProcessing();

  assert.equal(s.jobId, "NEW");
  assert.equal(closed, true); // old stream closed
  assert.equal(s.fetchedIdx.size, 0); // dedup cleared so chunks refetch
  assert.equal(s.totalChunks, 5);
  assert.equal(opened, 1); // stream reopened on the new id
});

test("_resumeProcessing keeps the same job_id when the url is unchanged", async () => {
  const s = makeSession();
  s.jobId = "SAME";
  s.fetchedIdx = new Set([0, 1]);
  s.eventSource = null;
  s.requestJob = async () => ({ job_id: "SAME", total_chunks: 4 });
  let opened = 0;
  s._openEventStream = () => {
    opened++;
  };
  s._sendPrioritizeHint = () => {};

  await s._resumeProcessing();

  assert.equal(s.jobId, "SAME");
  assert.equal(s.fetchedIdx.size, 2); // not cleared; it's the same job
  assert.equal(opened, 1); // reopened the (closed) stream
});

test("normalizeWatchUrl extracts a clean watch URL and strips extra params", () => {
  assert.equal(
    normalizeWatchUrl("https://www.youtube.com/watch?v=ABC123&t=42s&list=PLx"),
    "https://www.youtube.com/watch?v=ABC123",
  );
});

test("normalizeWatchUrl returns null for non-watch / empty inputs", () => {
  assert.equal(normalizeWatchUrl("https://www.youtube.com/feed/history"), null);
  assert.equal(normalizeWatchUrl(""), null);
  assert.equal(normalizeWatchUrl(null), null);
});

test("resolveSourceUrl uses the bridge's playing-video URL (miniplayer case)", () => {
  // location.href is the page being browsed; the bridge reports the real video.
  withBridge("https://www.youtube.com/watch?v=MINI42&t=10s", () => {
    assert.equal(resolveSourceUrl(), "https://www.youtube.com/watch?v=MINI42");
  });
});

test("resolveSourceUrl falls back to the page URL when the bridge has no answer", () => {
  // Non-YouTube page (no player): bridge answers empty -> use location.href.
  withBridge("", () => {
    assert.equal(resolveSourceUrl(), location.href);
  });
});

test("a YouTube ad (player .ad-showing) never drives fetch, buffer pause, or prioritize", () => {
  let ad = true;
  const player = { classList: { contains: (c) => ad && c === "ad-showing" } };
  let paused = 0;
  const video = { currentTime: 3, paused: false, closest: () => player, pause: () => paused++ };
  const s = new Session(video, { setBuffering() {} });
  s.chunkSeconds = 10;
  s.chunkOverlapSeconds = 0.5;
  s.jobId = "J";
  s.readyChunks.add(0);
  let fetched = 0;
  s.fetchAndQueueChunk = () => fetched++;

  s._syncChunkWindow();
  s._reconcileBufferState();
  s._sendPrioritizeHint();
  assert.equal(fetched, 0); // ad timestamps don't fetch
  assert.equal(paused, 0); // the ad is never paused for buffering
  assert.equal(s._prioritizeTimer, null); // no prioritize for ad time

  ad = false; // ad over: back to normal handling
  s._syncChunkWindow();
  s._reconcileBufferState();
  assert.equal(fetched, 1);
  assert.equal(paused, 1); // chunk 0 not decoded yet -> buffer pause
});

test("only a window of chunks around the playhead is fetched and kept decoded", () => {
  const s = new Session({ currentTime: 95, paused: true }, {}); // chunk 10
  s.chunkSeconds = 10;
  s.chunkOverlapSeconds = 0.5;
  s.totalChunks = 40;
  for (let i = 0; i < 40; i++) s.readyChunks.add(i);
  const fetched = [];
  s.fetchAndQueueChunk = (i) => fetched.push(i);
  s.chunks.set(0, { buffer: {}, playStart: 0 }); // far behind the playhead
  s.fetchedIdx.add(0);

  s._syncChunkWindow();
  assert.deepEqual(fetched, [9, 10, 11, 12, 13, 14, 15]); // cur-1 .. cur+ceil(40/9.5)
  assert.equal(s.chunks.has(0), false); // evicted
  assert.equal(s.fetchedIdx.has(0), false); // refetchable on a seek back
});

test("the video tail past total_chunks * stride counts as the last chunk", () => {
  const s = makeSession();
  s.totalChunks = 20; // covers 0..190 s
  s.chunks.set(19, { buffer: {}, playStart: 180.5 });
  assert.equal(s._isBuffered(190.4), true);
});
