import { siteConfig } from './site-config.js';

const deviceContent = {
  iphone: { kicker: 'IPHONE & IPAD', title: 'Your everyday\nwindow home.', description: 'Use a supported iPhone or iPad as a camera or viewer. Check a single room, open the camera wall, or settle into a bigger view on iPad.', note: 'Camera mode stays open on your camera device.' },
  mac: { kicker: 'MAC', title: 'A little window.\nBeside your work.', description: 'Keep a camera in its own window while you work. Open more views, review recordings, and use desktop controls on a familiar screen.', note: 'Mac can be a camera or a viewer.' },
  tv: { kicker: 'APPLE TV', title: 'Your cameras.\nThe big picture.', description: 'Bring your cameras to the biggest screen in the room. Browse the camera wall, open a full-screen view, and look back through recorded footage.', note: 'Viewer companion with device-code pairing.' },
  watch: { kicker: 'APPLE WATCH', title: 'A quick glance.\nRight on your wrist.', description: 'Check a camera, listen, or hold to talk through your paired iPhone. If that connection is unavailable, encrypted iCloud still images provide a fallback.', note: 'Live pictures and voice require the paired iPhone relay.' },
  vision: { kicker: 'APPLE VISION PRO', title: 'Give every camera\nits own space.', description: 'Open a separate window for each camera. Arrange your views around you and explore a camera’s controls and recorded timeline.', note: 'Viewer companion. Each camera opens in its own window.' },
};

const deviceButtons = [...document.querySelectorAll('[data-device]')].filter(element => element.tagName === 'BUTTON');
deviceButtons.forEach(button => button.addEventListener('click', () => {
  const device = button.dataset.device;
  const content = deviceContent[device];
  deviceButtons.forEach(item => item.setAttribute('aria-pressed', String(item === button)));
  document.querySelector('.device-visual').dataset.device = device;
  document.querySelector('#device-kicker').textContent = content.kicker;
  document.querySelector('#device-title').replaceChildren(...content.title.split('\n').flatMap((line, index) => index ? [document.createElement('br'), document.createTextNode(line)] : [document.createTextNode(line)]));
  document.querySelector('#device-description').textContent = content.description;
  document.querySelector('#device-footnote').textContent = content.note;
  document.querySelector('.display-toolbar span:last-child').textContent = device === 'watch' ? 'VIA IPHONE' : 'YOUR CAMERAS';
}));

document.querySelectorAll('[data-mode]').forEach(button => button.addEventListener('click', () => {
  const replay = button.dataset.mode === 'replay';
  document.querySelector('.replay-demo').classList.toggle('is-replay', replay);
  document.querySelectorAll('.segmented button').forEach(item => item.setAttribute('aria-pressed', String(item.dataset.mode === button.dataset.mode)));
  document.querySelector('#preview-state').textContent = replay ? 'PLAYBACK · 09:32' : '● LIVE';
  document.querySelector('#preview-title').textContent = replay ? 'A moment worth a second look.' : 'All quiet. All good.';
  document.querySelector('#preview-detail').textContent = replay ? 'Sample pet event · recorded timeline illustration.' : 'Your camera, at a glance.';
}));

if (siteConfig.betaUrl) {
  try {
    const url = new URL(siteConfig.betaUrl);
    if (url.protocol !== 'https:' || url.hostname !== 'testflight.apple.com' || !/^\/join\/[A-Za-z0-9]+\/?$/.test(url.pathname)) throw new Error('Invalid invitation');
    document.querySelectorAll('[data-beta-cta]').forEach(link => {
      link.href = url.href;
      link.firstChild.textContent = 'Join the beta ';
    });
    document.querySelector('#beta-status').textContent = 'Try MirrorMirror on TestFlight';
    const answer = document.querySelector('#beta-answer');
    const link = document.createElement('a');
    link.href = url.href; link.textContent = 'Join the public TestFlight beta'; link.className = 'text-link';
    answer.replaceChildren(link, document.createTextNode('. TestFlight will show the supported devices and build details before installation.'));
  } catch { console.warn('The beta invitation could not be enabled.'); }
}
document.querySelector('#year').textContent = new Date().getFullYear();
