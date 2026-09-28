// All helper traffic stays in the extension origin. Web pages cannot read
// processed audio or trigger local downloads through this worker.
const BACKEND = "http://127.0.0.1:8724";
const CLIENT_HEADER = { name: "X-Sitr-Music-Client", value: "extension" };
const jobIdOk = (id) => typeof id === "string" && /^[a-zA-Z0-9_-]+$/.test(id);
const heightOk = (height) => [0, 480, 720, 1080, 1440, 2160].includes(height);

function requestFor(message) {
  const id = message.jobId;
  switch (message.type) {
    case "capabilities": return { path: "/capabilities" };
    case "cache": return { path: "/cache" };
    case "clearCache": return { path: "/cache/clear", body: {} };
    case "process": {
      const url = new URL(message.url);
      if (!["http:", "https:"].includes(url.protocol)) throw new Error("Unsupported video URL");
      const body = { url: url.href };
      if (typeof message.model === "string") body.model = message.model;
      if (Array.isArray(message.keepStems)) body.keep_stems = message.keepStems;
      return { path: "/process", body };
    }
    case "status":
      if (jobIdOk(id)) return { path: `/status/${id}` };
      break;
    case "chunk":
      if (jobIdOk(id) && Number.isSafeInteger(message.index) && message.index >= 0) {
        return { path: `/chunk/${id}/${message.index}`, binary: true };
      }
      break;
    case "prioritize":
      if (jobIdOk(id) && Number.isSafeInteger(message.fromChunk) && message.fromChunk >= 0) {
        return { path: `/process/${id}/prioritize`, body: { from_chunk: message.fromChunk } };
      }
      break;
    case "cancel":
      if (jobIdOk(id)) return { path: `/process/${id}/cancel`, body: {} };
      break;
  }
  throw new Error("Invalid helper request");
}

function toBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  let text = "";
  for (let i = 0; i < bytes.length; i += 32768) {
    text += String.fromCharCode(...bytes.subarray(i, i + 32768));
  }
  return btoa(text);
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message || typeof message.type !== "string") return false;
  (async () => {
    try {
      if (message.type === "download") {
        if (!jobIdOk(message.jobId) || !["mp3", "mp4"].includes(message.format) || !heightOk(message.height)) {
          throw new Error("Invalid download request");
        }
        const filename = String(message.filename || "sitr-music").replace(/[/\\:*?"<>|\x00-\x1f]/g, " ").trim().slice(0, 120) || "sitr-music";
        const path = message.format === "mp4"
          ? `/video/${message.jobId}${message.height ? `?max_height=${message.height}` : ""}`
          : `/audio/${message.jobId}?format=mp3`;
        const id = await chrome.downloads.download({
          url: `${BACKEND}${path}`,
          filename: `${filename}.${message.format}`,
          headers: [CLIENT_HEADER],
        });
        sendResponse({ ok: true, data: { downloadId: id } });
        return;
      }
      const { path, body, binary } = requestFor(message);
      if (message.type === "process") {
        const helper = await fetch(`${BACKEND}/capabilities`, {
          headers: { [CLIENT_HEADER.name]: CLIENT_HEADER.value },
          cache: "no-store",
        });
        if (!helper.ok || (await helper.json()).product_id !== "sitr-music") {
          throw new Error("Sitr Music helper unavailable");
        }
      }
      const response = await fetch(`${BACKEND}${path}`, {
        method: body ? "POST" : "GET",
        headers: { [CLIENT_HEADER.name]: CLIENT_HEADER.value, ...(body ? { "Content-Type": "application/json" } : {}) },
        ...(body ? { body: JSON.stringify(body) } : {}),
        cache: message.type === "chunk" ? "default" : "no-store",
      });
      if (!response.ok) throw new Error(`${response.status}: ${await response.text()}`);
      const data = binary ? toBase64(await response.arrayBuffer()) : await response.json();
      if (message.type === "capabilities" && data.product_id !== "sitr-music") {
        throw new Error("Sitr Music helper unavailable");
      }
      sendResponse({ ok: true, data });
    } catch (error) {
      sendResponse({ ok: false, error: String(error) });
    }
  })();
  return true;
});
