import test from 'node:test';
import assert from 'node:assert/strict';
import { selectRelease, releasesUrl, assetName } from './release.js';
function release(overrides = {}) {
  return { tag_name: 'android-demo-1.0.0-42', prerelease: true, draft: false, assets: [{ name: assetName, state: 'uploaded', size: 104857600, browser_download_url: `${releasesUrl}/download/android-demo-1.0.0-42/${assetName}` }], ...overrides };
}
test('finds an installable demo prerelease and reports its actual size', () => {
  assert.deepEqual(selectRelease([release()]), { version: '1.0.0-42', size: '100.0 MB', url: `${releasesUrl}/download/android-demo-1.0.0-42/${assetName}`, notes: `${releasesUrl}/tag/android-demo-1.0.0-42` });
});
test('skips draft, unrelated and incomplete releases', () => {
  assert.equal(selectRelease([release({ draft: true }), release({ tag_name: 'v1.0.0' }), release({ assets: [] })]), null);
});
test('never makes a download button from a foreign or malformed URL', () => {
  assert.equal(selectRelease([release({ assets: [{ name: assetName, state: 'uploaded', size: 1, browser_download_url: 'https://example.com/app.apk' }] })]), null);
});
test('falls back to a prior complete release while a new release is being uploaded', () => {
  assert.equal(selectRelease([release({ tag_name: 'android-demo-1.0.0-43', assets: [] }), release()]).version, '1.0.0-42');
});
test('handles an empty or invalid API response without inventing a download', () => {
  assert.equal(selectRelease([]), null);
  assert.equal(selectRelease({ message: 'API rate limit exceeded' }), null);
});
