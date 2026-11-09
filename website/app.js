import { repository, releasesUrl, selectRelease } from './release.js';

const descriptions = {
  ai: ['AI & Agents', 'From a quick idea to your next deep dive.'],
  observability: ['Observability', 'Follow your curiosity beneath the surface.'],
  platform: ['Platform engineering', 'Find the systems behind a better developer day.'],
};
for (const button of document.querySelectorAll('[data-topic]')) {
  button.addEventListener('click', () => {
    for (const other of document.querySelectorAll('[data-topic]')) other.setAttribute('aria-pressed', String(other === button));
    const [title, description] = descriptions[button.dataset.topic];
    document.querySelector('#signal-title').textContent = title;
    document.querySelector('#signal-description').textContent = description;
  });
}
const motionButton = document.querySelector('#motion-toggle');
const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
let paused = reducedMotion.matches;
function updateMotion() {
  document.querySelector('#radar').classList.toggle('motion-paused', paused);
  motionButton.textContent = reducedMotion.matches ? 'Motion reduced' : paused ? 'Resume motion' : 'Pause motion';
  motionButton.setAttribute('aria-pressed', String(paused));
  motionButton.disabled = reducedMotion.matches;
}
motionButton.addEventListener('click', () => { paused = !paused; updateMotion(); });
reducedMotion.addEventListener('change', () => { paused = reducedMotion.matches; updateMotion(); });
updateMotion();

async function loadRelease() {
  const status = document.querySelector('#release-status');
  try {
    const response = await fetch(`https://api.github.com/repos/${repository}/releases?per_page=30`, {
      headers: { Accept: 'application/vnd.github+json' }, signal: AbortSignal.timeout(8000),
    });
    if (!response.ok) throw new Error(`Release check failed: ${response.status}`);
    const release = selectRelease(await response.json());
    if (!release) {
      status.textContent = 'The first demo APK is being prepared. Check GitHub Releases for availability.';
      return;
    }
    status.textContent = `Demo ${release.version} · ${release.size} · APK`;
    const download = document.querySelector('#apk-download');
    download.href = release.url;
    download.textContent = 'Download demo APK ↓';
    document.querySelector('#release-notes').href = release.notes;
  } catch {
    status.textContent = 'Release details are temporarily unavailable. You can still check downloads on GitHub.';
    document.querySelector('#apk-download').href = releasesUrl;
  }
}
loadRelease();
