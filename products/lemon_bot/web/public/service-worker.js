/* No private API caching. Notifications always reconcile through authenticated fetch. */
self.addEventListener('push', event => {
  let payload;
  try { payload = event.data?.json(); } catch { return; }
  if (payload?.version !== 1 || typeof payload.notificationId !== 'string') return;
  event.waitUntil(self.registration.showNotification(payload.title || 'Lemon Bot', {
    body: payload.body || 'Your teammate has an update.', tag: payload.notificationId,
    data: { notificationId: payload.notificationId, deepLink: payload.deepLink },
  }));
});
self.addEventListener('notificationclick', event => {
  event.notification.close();
  const data = event.notification.data;
  const url = new URL('/', self.location.origin);
  if (typeof data?.deepLink === 'string' && data.deepLink.startsWith('lemonbot://workspace/')) {
    url.hash = `link=${encodeURIComponent(data.deepLink)}`;
  } else if (typeof data?.notificationId === 'string') {
    url.hash = 'screen=inbox';
  }
  event.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(async windows => {
    const client = windows.find(window => new URL(window.url).origin === self.location.origin);
    if (client) { await client.focus(); client.postMessage({ type: 'notification_navigation', deepLink: data?.deepLink }); }
    else await self.clients.openWindow(url.href);
  }));
});
