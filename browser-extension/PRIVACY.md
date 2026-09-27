# Sitr Music privacy policy

*Last updated: 2026-09-27*

Sitr Music is a browser extension that works with the Sitr app on your Mac to reduce music in web videos.

**What the extension handles.** When you press **Remove music** on a video, the extension sends that video's address
and your audio setting to the Sitr Music helper running on your own Mac at `127.0.0.1:8724`. It sends nothing before
you press the button.

**Where data goes.** The helper downloads the video's audio from the video's own website, separates the voice on your
Mac, and keeps temporary files in a local cache for up to seven days. You can clear the cache from the extension's
popup. Nothing is sent to Sitr's developers or any other server. The extension has no analytics, ads, or tracking.

**Stored settings.** Your choice to keep sound effects is saved with `chrome.storage.sync`, which your browser may sync
between your own signed-in browsers.

**Selling or sharing.** No data is sold or shared with third parties, or used for anything other than removing music
from the video you chose.

**Contact.** Questions: https://github.com/haithamassoli/Sitr/issues

---

# سياسة الخصوصية لإضافة Sitr Music

تعمل إضافة Sitr Music مع تطبيق Sitr على جهاز Mac لتخفيف الموسيقى في فيديوهات الويب. عندما تضغط **إزالة الموسيقى**،
ترسل الإضافة عنوان ذلك الفيديو وإعداد الصوت إلى مساعد Sitr Music على جهازك فقط (`127.0.0.1:8724`)، ولا ترسل شيئًا قبل
الضغط. ينزّل المساعد صوت الفيديو من موقعه ويعالجه على جهازك، ويحتفظ بملفات مؤقتة حتى سبعة أيام يمكنك حذفها من نافذة
الإضافة. لا يُرسل شيء إلى مطوّري Sitr أو إلى أي خادم آخر، ولا توجد تحليلات أو إعلانات أو تتبّع، ولا تُباع أي بيانات أو
تُشارك.
