export const repo = 'https://github.com/haithamassoli/Sitr';

// Resolved at build time, so the site must rebuild when a release is published (see .github/workflows/web.yml).
// Any failure falls back to the releases page rather than breaking the build.
async function latest(): Promise<{ version: string | null; url: string }> {
  const fallback = { version: null, url: `${repo}/releases/latest` };
  try {
    const res = await fetch('https://api.github.com/repos/haithamassoli/Sitr/releases/latest', {
      headers: process.env.GITHUB_TOKEN ? { authorization: `Bearer ${process.env.GITHUB_TOKEN}` } : {},
    });
    if (!res.ok) return fallback;
    const release = await res.json();
    const dmg = release.assets.find((a: { name: string }) => a.name.endsWith('.dmg'));
    return dmg ? { version: release.tag_name.replace(/^v/, ''), url: dmg.browser_download_url } : fallback;
  } catch {
    return fallback;
  }
}

export const release = await latest();
