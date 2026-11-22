const notice = document.querySelector('#preview-notice');
const noticeKey = 'pasteboard-preview-notice-1';
const canUseDialog = typeof notice.showModal === 'function';
let returnFocus;
function showNotice(trigger) {
  returnFocus = trigger || document.querySelector('.hero-actions .button');
  if (canUseDialog && !notice.open) notice.showModal();
}
document.querySelectorAll('[data-preview]').forEach(button => {
  button.addEventListener('click', () => showNotice(button));
});
notice.addEventListener('close', () => {
  try { sessionStorage.setItem(noticeKey, 'seen'); } catch {}
  returnFocus?.focus({ preventScroll: true });
});
let seen = false;
try { seen = sessionStorage.getItem(noticeKey) === 'seen'; } catch {}
if (!seen) showNotice();
fetch('release.json').then(response => {
  if (!response.ok) throw new Error('Release details unavailable');
  return response.json();
}).then(release => {
  document.querySelectorAll('[data-version]').forEach(label => { label.textContent = release.version; });
  document.querySelector('[data-download-size]').textContent = `${(release.bytes / 1024 / 1024).toFixed(1)} MB download`;
}).catch(() => {});
