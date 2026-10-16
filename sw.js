// Service Worker: App-Shell offline verfügbar, HTML immer zuerst vom Netz (damit neue Versionen sofort ankommen)
const CACHE = 'set-duell-v2';
const SHELL = ['./', 'index.html', 'i18n.js', 'config.js', 'manifest.webmanifest', 'icons/icon-192.png', 'icons/icon-512.png'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => Promise.all(SHELL.map((u) => c.add(u).catch(() => {})))).then(() => self.skipWaiting()));
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== location.origin) return;           // Supabase, Fonts, CDN: nicht anfassen
  if (req.mode === 'navigate') {                        // Seiten: Netz zuerst, sonst gespeicherte App
    e.respondWith(
      fetch(req).then((r) => { const copy = r.clone(); caches.open(CACHE).then((c) => c.put('index.html', copy)); return r; })
        .catch(() => caches.match('index.html').then((r) => r || caches.match('./')))
    );
    return;
  }
  e.respondWith(                                        // Dateien: Cache sofort, im Hintergrund aktualisieren
    caches.match(req).then((hit) => {
      const net = fetch(req).then((r) => { if (r.ok) { const copy = r.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); } return r; }).catch(() => hit);
      return hit || net;
    })
  );
});
