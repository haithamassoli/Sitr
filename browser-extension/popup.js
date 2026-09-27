import { isArabic, t } from "./i18n.js";

const $ = (id) => document.getElementById(id);

async function checkHelper() {
  $("status").className = "status";
  $("status").textContent = t("جارٍ فحص الاتصال بتطبيق ستر…", "Checking the Sitr app…");
  try {
    const response = await chrome.runtime.sendMessage({ type: "capabilities" });
    if (!response?.ok) throw new Error(response?.error || "Helper unavailable");
    $("status").className = "status ready";
    $("status").textContent = t("جاهز لإزالة الموسيقى", "Ready to remove music");
    $("offline").hidden = true;
    $("ready").hidden = false;
    await refreshCache();
  } catch {
    $("status").className = "status offline";
    $("status").textContent = t("الخدمة المحلية غير متصلة", "Sitr Music is not connected");
    $("offline").hidden = false;
    $("ready").hidden = true;
    $("cacheSize").textContent = "—";
    $("clearCache").disabled = true;
  }
}

async function refreshCache() {
  try {
    const response = await chrome.runtime.sendMessage({ type: "cache" });
    if (!response?.ok) throw new Error(response?.error || "Cache unavailable");
    const bytes = response.data.total_bytes || 0;
    $("cacheSize").textContent = bytes ? `${(bytes / 1048576).toFixed(1)} MB` : t("لا توجد", "None");
    $("clearCache").disabled = !bytes;
  } catch {
    $("cacheSize").textContent = t("غير معروف", "Unknown");
    $("clearCache").disabled = true;
  }
}

async function clearCache() {
  const button = $("clearCache");
  if (button.dataset.confirm !== "yes") {
    button.dataset.confirm = "yes";
    button.textContent = t("تأكيد الحذف", "Confirm delete");
    $("message").textContent = t("ستُعالج الفيديوهات مجددًا عند مشاهدتها.", "Videos will be processed again next time.");
    setTimeout(() => {
      button.dataset.confirm = "";
      button.textContent = t("حذفها", "Delete");
    }, 4000);
    return;
  }
  button.dataset.confirm = "";
  button.textContent = t("حذفها", "Delete");
  try {
    const response = await chrome.runtime.sendMessage({ type: "clearCache" });
    if (!response?.ok) throw new Error(response?.error || "Clear failed");
    $("message").textContent = t("حُذفت الملفات المؤقتة.", "Temporary files deleted.");
    await refreshCache();
  } catch {
    $("message").textContent = t("تعذّر الحذف. تأكد من تشغيل تطبيق ستر.", "Could not delete files. Check that Sitr is running.");
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!isArabic()) {
    document.documentElement.lang = "en";
    document.documentElement.dir = "ltr";
    for (const element of document.querySelectorAll("[data-en]")) {
      element.textContent = element.dataset.en;
    }
  }
  const { keepStems } = await chrome.storage.sync.get("keepStems");
  $("effects").checked = keepStems?.includes("other") || false;
  $("effects").addEventListener("change", async () => {
    await chrome.storage.sync.set({ keepStems: $("effects").checked ? ["vocals", "other"] : ["vocals"] });
    $("message").textContent = t("حُفظ الخيار للفيديوهات التالية.", "Saved for future videos.");
  });
  $("retry").addEventListener("click", checkHelper);
  $("clearCache").addEventListener("click", clearCache);
  await checkHelper();
});
