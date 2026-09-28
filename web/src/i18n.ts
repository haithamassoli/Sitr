const en = {
  dir: 'ltr',
  ogLocale: 'en_US',
  arrow: '↗',
  title: 'Sitr — A quieter screen, on your terms',
  description:
    'Sitr is a free, open-source macOS menu bar app that hides people on your screen as they appear. On-device processing, no account, no network access.',
  ogAlt: 'Sitr: a quieter screen, on your terms. Private, on-device protection for Mac.',
  home: 'Sitr home',
  mainNav: 'Main navigation',
  nav: { features: 'Features', how: 'How it works', privacy: 'Privacy' },
  otherLang: { label: 'العربية', code: 'ar' },
  getSitr: 'Get Sitr',
  eyebrow: 'A private space for your screen',
  h1: ['A quieter screen.', 'On your terms.'],
  heroCopy:
    'Sitr covers people on your Mac as they appear. Choose who to hide, where to protect, and how it looks — while everything stays on your device.',
  download: 'Download for Mac',
  explore: 'Explore on GitHub',
  requirements: 'Free & open source · macOS 15+ · Apple silicon',
  artLabel: 'Illustration of Sitr covering a person in a Mac browser window',
  mock: { menu: 'File   Edit   View', active: 'Sitr active', hidden: 'Person hidden', on: 'Protection is on', onSub: 'Your chosen apps are covered', caption: 'Illustrative preview' },
  trust: ['Processed entirely on your Mac', 'No account or cloud service', 'Open source and verifiable'],
  features: {
    kicker: 'Made for your everyday screen',
    title: 'Protection that fits the way you use your Mac.',
    body: 'Sitr lives quietly in your menu bar and gives you control over what appears across the apps you choose.',
    items: [
      ['01 / CHOOSE', 'Your choice of people', 'Hide women, men, or everyone. Strict Mode can also cover people Sitr cannot classify.'],
      ['02 / CUSTOMIZE', 'Three ways to cover', 'Use a soft blur, pixelation, or a solid block. Adjust the look in Settings at any time.'],
      ['03 / CONTROL', 'Protection where you want it', 'Choose which apps Sitr protects, pause from the menu bar, or hold your shortcut to reveal temporarily.'],
    ],
  },
  how: {
    kicker: 'Simple to start',
    title: 'Set it once. Stay in your flow.',
    body: 'Sitr works in the background after a short setup. You can revisit every choice whenever you need.',
    steps: [
      ['Install the Mac app', 'Open the DMG from the latest GitHub release and drag Sitr to Applications.'],
      ['Allow Screen Recording', 'macOS asks for permission so Sitr can find people on your screen. Sitr does not record audio.'],
      ['Choose your protection', 'Pick who to hide, a cover style, and the apps to protect. Sitr stays in your menu bar.'],
    ],
  },
  privacy: {
    kicker: 'Built for privacy',
    title: 'Your screen stays yours.',
    body: 'Detection runs on your Mac. Sitr is sandboxed without network access, and screen frames stay in memory instead of being saved to disk.',
    verify: 'See how to verify it yourself',
    verifyUrl: '#verify-the-privacy-claim',
    note: ['Nothing to upload.', 'Nothing to sign in to.', 'Just your screen, your rules.'],
    small: 'Open source under GPL-3.0. The app requires Screen Recording permission to protect your screen.',
  },
  cta: {
    kicker: 'Ready when you are',
    title: 'Make space for what matters.',
    body: 'Download the DMG from the latest GitHub release. Requires macOS 15 or later and Apple silicon.',
    button: 'Get Sitr for Mac',
  },
  footer: { releases: 'Releases', readme: 'README.md', guide: 'Guide', made: 'Made for Mac.' },
};

type Dict = typeof en;

const ar: Dict = {
  dir: 'rtl',
  ogLocale: 'ar_AR',
  arrow: '↖',
  title: 'Sitr «ستر» — شاشة أهدأ، بشروطك',
  description:
    'Sitr تطبيق مجاني ومفتوح المصدر لشريط القائمة في macOS يخفي الأشخاص على شاشتك لحظة ظهورهم. المعالجة على جهازك، بلا حساب ولا اتصال بالشبكة.',
  ogAlt: 'Sitr: شاشة أهدأ، بشروطك. حماية خاصة تعمل على جهاز Mac.',
  home: 'الصفحة الرئيسية لـ Sitr',
  mainNav: 'التنقل الرئيسي',
  nav: { features: 'المزايا', how: 'طريقة العمل', privacy: 'الخصوصية' },
  otherLang: { label: 'English', code: 'en' },
  getSitr: 'احصل على Sitr',
  eyebrow: 'مساحة خاصة لشاشتك',
  h1: ['شاشة أهدأ.', 'بشروطك.'],
  heroCopy:
    'يغطي Sitr الأشخاص على شاشة جهاز Mac لحظة ظهورهم. اختر مَن تريد إخفاءه، وأين تريد الحماية، وكيف يبدو الغطاء، وكل ذلك يبقى على جهازك.',
  download: 'نزّله لجهاز Mac',
  explore: 'استكشفه على GitHub',
  requirements: 'مجاني ومفتوح المصدر · macOS 15 أو أحدث · Apple silicon',
  artLabel: 'رسم توضيحي لـ Sitr وهو يغطي شخصًا في نافذة متصفح على Mac',
  mock: { menu: 'ملف   تحرير   عرض', active: 'Sitr يعمل', hidden: 'تم إخفاء شخص', on: 'الحماية مفعّلة', onSub: 'التطبيقات التي اخترتها محمية', caption: 'معاينة توضيحية' },
  trust: ['تتم المعالجة بالكامل على جهازك', 'بلا حساب ولا خدمة سحابية', 'مفتوح المصدر وقابل للتحقق'],
  features: {
    kicker: 'مصمم لشاشتك اليومية',
    title: 'حماية تناسب طريقة استخدامك لجهازك.',
    body: 'يعمل Sitr بهدوء من شريط القائمة ويمنحك التحكم فيما يظهر في التطبيقات التي تختارها.',
    items: [
      ['01 / اختر', 'أنت تختار مَن يُخفى', 'أخفِ النساء أو الرجال أو الجميع. ويستطيع الوضع الصارم أيضًا تغطية الأشخاص الذين لا يستطيع Sitr تصنيفهم.'],
      ['02 / خصّص', 'ثلاث طرق للتغطية', 'تمويه ناعم أو بكسلة أو لون مصمت، ويمكنك تغيير المظهر من الإعدادات في أي وقت.'],
      ['03 / تحكّم', 'حماية حيث تريدها', 'اختر التطبيقات التي يحميها Sitr، وأوقفه مؤقتًا من شريط القائمة، أو اضغط مطولًا على اختصارك للكشف المؤقت.'],
    ],
  },
  how: {
    kicker: 'بداية بسيطة',
    title: 'اضبطه مرة واحدة، وتابع عملك.',
    body: 'يعمل Sitr في الخلفية بعد إعداد قصير، ويمكنك مراجعة كل خيار متى احتجت.',
    steps: [
      ['ثبّت التطبيق', 'افتح ملف DMG من أحدث إصدار على GitHub واسحب Sitr إلى مجلد Applications.'],
      ['اسمح بتسجيل الشاشة', 'يطلب macOS إذنًا ليتمكن Sitr من اكتشاف الأشخاص على شاشتك. لا يسجّل Sitr الصوت.'],
      ['اختر حمايتك', 'حدّد مَن تريد إخفاءه وطريقة التغطية والتطبيقات المحمية، ويبقى Sitr في شريط القائمة.'],
    ],
  },
  privacy: {
    kicker: 'مبني للخصوصية',
    title: 'شاشتك تبقى لك.',
    body: 'يعمل الاكتشاف على جهازك. Sitr يعمل داخل صندوق الحماية بلا صلاحية للشبكة، وتبقى إطارات الشاشة في الذاكرة ولا تُحفظ على القرص.',
    verify: 'تحقّق من ذلك بنفسك',
    verifyUrl: '#التحقق-من-الخصوصية',
    note: ['لا شيء يُرفع.', 'لا حساب لتسجيل الدخول.', 'شاشتك، وقواعدك.'],
    small: 'مفتوح المصدر برخصة GPL-3.0. يحتاج التطبيق إلى إذن تسجيل الشاشة ليحمي شاشتك.',
  },
  cta: {
    kicker: 'جاهز متى كنت جاهزًا',
    title: 'أفسح المجال لما يهمّك.',
    body: 'نزّل ملف DMG من أحدث إصدار على GitHub. يتطلب macOS 15 أو أحدث وجهاز Mac بشريحة Apple silicon.',
    button: 'نزّل Sitr لجهاز Mac',
  },
  footer: { releases: 'الإصدارات', readme: 'README.ar.md', guide: 'الدليل', made: 'صُنع لأجهزة Mac.' },
};

export const dicts = { en, ar };
export type Lang = keyof typeof dicts;
