// Rev Barbell service worker: shows push notifications and opens the right screen when tapped.
// No offline caching, so members always get the latest app.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { body: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Rev Barbell', {
    body: d.body || '',
    icon: 'icons/icon-192.png?v=2',
    badge: 'icons/badge-96.png?v=2',
    tag: d.tag || undefined,
    renotify: !!d.tag,
    data: { url: d.url || './', focusOnly: d.tag === 'rest' }
  }));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || './';
  e.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    // the athlete app (index), the coach app (coach.html) and REV Admin (admin.html) share this worker: reuse a window of the same app
    const page = u => { const p = new URL(u, self.registration.scope).pathname; return /coach\.html$/.test(p) ? 'coach' : /admin\.html$/.test(p) ? 'admin' : 'app'; };
    const want = page(url);
    for (const c of all) {
      // rest timer: just bring the app back, don't reload the workout
      if (c.url.startsWith(self.registration.scope) && page(c.url) === want) { await c.focus(); if (e.notification.data && e.notification.data.focusOnly) return; return c.navigate(url).catch(() => {}); }
    }
    return self.clients.openWindow(url);
  })());
});
