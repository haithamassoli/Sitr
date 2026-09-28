// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

export default defineConfig({
  site: 'https://sitr.assoli.site',
  trailingSlash: 'always',
  i18n: { locales: ['en', 'ar'], defaultLocale: 'en' },
  integrations: [sitemap({ i18n: { defaultLocale: 'en', locales: { en: 'en', ar: 'ar' } } })],
});
