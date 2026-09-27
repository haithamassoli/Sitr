export const isArabic = () => (globalThis.navigator?.language || "en").toLowerCase().startsWith("ar");
export const t = (arabic, english) => isArabic() ? arabic : english;
