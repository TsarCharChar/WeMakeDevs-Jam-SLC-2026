export const repository = 'TsarCharChar/WeMakeDevs-Jam-SLC-2026';
export const releasesUrl = `https://github.com/${repository}/releases`;
export const assetName = 'confellow-demo.apk';

// Demo releases are prereleases: GitHub's /releases/latest excludes them.
export function selectRelease(releases) {
  if (!Array.isArray(releases)) return null;
  for (const release of releases) {
    if (release.draft || !release.tag_name?.startsWith('android-demo-')) continue;
    const asset = release.assets?.find((item) => item.name === assetName && item.state === 'uploaded' && item.size > 0);
    if (!asset) continue;
    const expected = `${releasesUrl}/download/${encodeURIComponent(release.tag_name)}/${assetName}`;
    if (asset.browser_download_url !== expected) continue;
    return { version: release.tag_name.replace('android-demo-', ''), size: `${(asset.size / 1024 / 1024).toFixed(1)} MB`, url: expected, notes: `${releasesUrl}/tag/${encodeURIComponent(release.tag_name)}` };
  }
  return null;
}
