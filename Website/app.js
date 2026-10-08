import { siteConfig } from './site-config.js';

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
