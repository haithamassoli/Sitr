// Unit tests for settings.js — the shared config + chrome.storage cache.
import { test } from "node:test";
import assert from "node:assert/strict";

import {
  SYNC_TOLERANCE_S,
  SYNC_CHECK_MS,
  settings,
  loadSettings,
} from "../settings.js";

test("default constants are sane", () => {
  assert.ok(SYNC_TOLERANCE_S > 0 && SYNC_TOLERANCE_S < 1);
  assert.ok(SYNC_CHECK_MS >= 50);
});

test("loadSettings overlays stored values onto the defaults", async () => {
  chrome.storage.sync.get = async () => ({
    model: "htdemucs_ft",
    keepStems: ["vocals", "other"],
  });
  await loadSettings();
  assert.equal(settings.model, "htdemucs_ft");
  assert.deepEqual(settings.keepStems, ["vocals", "other"]);
});

test("loadSettings falls back to defaults when storage throws", async () => {
  chrome.storage.sync.get = async () => {
    throw new Error("permission denied");
  };
  // Must not reject — a storage failure leaves the in-memory defaults intact.
  await loadSettings();
});
