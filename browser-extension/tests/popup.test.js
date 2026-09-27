import { test } from "node:test";
import assert from "node:assert/strict";

function makeElement() {
  const handlers = {};
  return {
    className: "", textContent: "", hidden: false, disabled: false, checked: false, dataset: {},
    addEventListener: (name, callback) => { handlers[name] = callback; },
    trigger: async (name) => handlers[name](),
  };
}

for (const locale of ["ar-JO", "en-US"]) {
  test(`popup guides users and saves effects in ${locale}`, async () => {
    const ids = ["status", "offline", "ready", "cacheSize", "clearCache", "message", "effects", "retry"];
    const elements = Object.fromEntries(ids.map((id) => [id, makeElement()]));
    const staticText = { dataset: { en: "English heading" }, textContent: "عنوان عربي" };
    let onReady;
    globalThis.document = {
      documentElement: { lang: "ar", dir: "rtl" },
      getElementById: (id) => elements[id],
      querySelectorAll: () => [staticText],
      addEventListener: (_name, callback) => { onReady = callback; },
    };
    Object.defineProperty(globalThis, "navigator", { value: { language: locale }, configurable: true });
    let connected = false;
    let saved;
    globalThis.chrome = {
      runtime: { sendMessage: async (message) => {
        if (message.type === "capabilities") return connected ? { ok: true, data: { product_id: "sitr-music" } } : { ok: false };
        if (message.type === "cache") return { ok: true, data: { total_bytes: 1048576 } };
        throw new Error("unexpected request");
      } },
      storage: { sync: {
        get: async () => ({ keepStems: ["vocals"] }),
        set: async (value) => { saved = value; },
      } },
    };
    await import(`../popup.js?locale=${locale}`);
    await onReady();
    assert.equal(elements.offline.hidden, false);
    assert.equal(elements.ready.hidden, true);
    assert.equal(document.documentElement.dir, locale.startsWith("ar") ? "rtl" : "ltr");
    assert.equal(staticText.textContent, locale.startsWith("ar") ? "عنوان عربي" : "English heading");
    connected = true;
    await elements.retry.trigger("click");
    assert.equal(elements.offline.hidden, true);
    assert.equal(elements.ready.hidden, false);
    assert.equal(elements.cacheSize.textContent, "1.0 MB");
    assert.equal(elements.status.textContent, locale.startsWith("ar") ? "جاهز لإزالة الموسيقى" : "Ready to remove music");
    elements.effects.checked = true;
    await elements.effects.trigger("change");
    assert.deepEqual(saved, { keepStems: ["vocals", "other"] });
  });
}
