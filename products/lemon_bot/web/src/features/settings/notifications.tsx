import { useState } from 'react';
import { nonce, type NotificationPreferences } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { useQuery, ErrorNotice, Loading, formatTime } from '../../ui';
import { allPages, useIntent, IntentNotice, Toggle } from './shared';

export function NotificationSettings() {
  const { client, device, refresh, snapshot } = useApp();
  const me = useQuery('settings:notification-user', () => client.call('GET /me'));
  const capabilities = useQuery('settings:push-capabilities', () => client.call('GET /capabilities'));
  const current = useQuery(`settings:push-device:${device?.id ?? 'none'}`, async () => {
    const devices = await allPages(cursor => client.call('GET /devices', { query: { cursor, limit: 200 } }));
    return devices.find(value => value.id === device?.id) ?? null;
  });
  const bots = useQuery('settings:notification-bots', () => allPages(cursor => client.call('GET /bots', { query: { cursor, limit: 200 } })));
  const [permission, setPermission] = useState<NotificationPermission | 'unsupported'>(typeof Notification === 'undefined' ? 'unsupported' : Notification.permission);
  const [subscriptionStatus, setSubscriptionStatus] = useState('Not checked in this visit');
  const intent = useIntent(async () => { await Promise.all([me.reload(), current.reload(), capabilities.reload(), bots.reload(), refresh()]); if (typeof Notification !== 'undefined') setPermission(Notification.permission); });
  const browserSupported = typeof window !== 'undefined' && window.isSecureContext && 'serviceWorker' in navigator && 'PushManager' in window && typeof Notification !== 'undefined';
  async function enablePush() {
    const registeredDevice = current.data;
    if (!registeredDevice || !capabilities.data?.webPush || !capabilities.data.vapidPublicKey) return;
    await intent.run(async () => {
      const granted = await Notification.requestPermission(); setPermission(granted);
      if (granted !== 'granted') { setSubscriptionStatus(granted === 'denied' ? 'Browser permission denied' : 'Permission not granted'); return; }
      const registration = await navigator.serviceWorker.register('/service-worker.js', { scope: '/' });
      await navigator.serviceWorker.ready;
      const key = capabilities.data!.vapidPublicKey!;
      const raw = atob(key.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - key.length % 4) % 4));
      const applicationServerKey = Uint8Array.from(raw, character => character.charCodeAt(0));
      let existing = await registration.pushManager.getSubscription();
      const existingKey = existing?.options.applicationServerKey;
      if (existing && existingKey && (existingKey.byteLength !== applicationServerKey.byteLength || new Uint8Array(existingKey).some((byte, index) => byte !== applicationServerKey[index]))) {
        if (!await existing.unsubscribe()) throw new Error('Could not update this browser’s notification subscription after the server settings changed. Ask your administrator for help.');
        existing = null;
      }
      const subscription = existing ?? await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey });
      const json = subscription.toJSON();
      if (!json.endpoint || !json.keys?.p256dh || !json.keys.auth) throw new Error('Browser did not return a complete Web Push subscription.');
      const saved = await client.call('PATCH /devices/:id', { params: { id: registeredDevice.id }, body: { revision: registeredDevice.revision, clientNonce: nonce(), pushEnabled: true, push: { kind: 'web_push', endpoint: json.endpoint, keys: { p256dh: json.keys.p256dh, auth: json.keys.auth } } } });
      current.setData(saved); setSubscriptionStatus('Your browser is subscribed. Server delivery is shown above.'); await refresh();
    });
  }
  async function disablePush() {
    if (!current.data) return;
    const saved = await intent.run(() => client.call('PATCH /devices/:id', { params: { id: current.data!.id }, body: { push: null, pushEnabled: false, revision: current.data!.revision, clientNonce: nonce() } }));
    if (saved) { current.setData(saved); setSubscriptionStatus('Delivery disabled for this device. Browser subscription is retained for other signed-in accounts on this installation.'); await refresh(); }
  }
  return <div className="stack"><IntentNotice intent={intent} /><ErrorNotice error={me.error} /><ErrorNotice error={capabilities.error} />{me.loading && !me.data && <Loading />}{me.data && <PreferenceEditor key={me.data.revision} value={me.data.notifications} disabled={intent.disabled} onSave={async notifications => { const saved = await intent.run(() => client.call('PATCH /me', { body: { notifications, revision: me.data!.revision, clientNonce: nonce() } })); if (saved) { me.setData(saved); await refresh(); } }} />}
  <section className="panel stack">
    <h2>Browser & device delivery</h2>
    <dl className="settings-facts">
      <dt>Browser permission</dt><dd>{permission}</dd>
      <dt>Browser notifications (server)</dt><dd>{capabilities.data ? capabilities.data.webPush ? 'On' : 'Not set up on this server. Ask your administrator to turn on browser notifications.' : capabilities.error ? 'Couldn’t check server notifications. Try Reload.' : 'Checking server notifications…'}</dd>
      <dt>iPhone notifications (server)</dt><dd>{capabilities.data ? capabilities.data.apns ? 'On' : 'Not set up on this server. Ask your administrator to turn on iPhone notifications.' : capabilities.error ? 'Couldn’t check server notifications. Try Reload.' : 'Checking server notifications…'}</dd>
      <dt>This browser</dt><dd>{current.data ? `${current.data.name} · ${current.data.id} · ${current.data.pushEnabled ? 'delivery enabled' : 'delivery disabled'} · last seen ${formatTime(current.data.lastSeenAtMs)}` : current.data === null ? 'This browser isn’t registered yet. Reload the page. If it still shows this, sign in again.' : current.error ? 'Couldn’t check this browser’s registration. Try Reload.' : 'Checking this browser’s registration…'}</dd>
      <dt>Browser subscription</dt><dd>{subscriptionStatus}</dd>
    </dl>
    <ErrorNotice error={current.error} />
    {!browserSupported && <p role="status">Web Push needs a supported browser in a secure HTTPS context (or trusted loopback).</p>}
    {permission === 'denied' && <p role="alert">Permission denied in this browser. Open the site permissions beside the address bar, allow notifications, then inspect again. Product settings cannot override an OS/browser denial.</p>}
    <div className="row">
      <button className="primary" disabled={intent.disabled || !browserSupported || permission === 'denied' || !capabilities.data?.webPush || !capabilities.data.vapidPublicKey || !current.data} onClick={() => void enablePush()}>Enable Web Push on this device</button>
      <button disabled={intent.disabled || !current.data} onClick={() => void disablePush()}>Disable this device’s delivery</button>
      <button disabled={intent.busy || !browserSupported} onClick={() => void intent.run(async () => { setPermission(Notification.permission); const registration = await navigator.serviceWorker.getRegistration('/'); const subscription = await registration?.pushManager.getSubscription(); setSubscriptionStatus(subscription ? 'Your browser is subscribed. Server delivery is shown above.' : 'Your browser isn’t subscribed.'); await current.reload(); })}>Check browser status</button>
    </div>
    <p className="muted small">The in-app inbox always keeps your alerts, even when browser notifications are off. Hidden Bots don’t send notifications, but they keep working. <span title="Enabling notifications replaces an outdated browser subscription if your administrator changed the server’s VAPID keys.">About server changes</span></p>
  </section>
  <section className="panel stack"><h2>Per-Bot notifications</h2><ErrorNotice error={bots.error} />{bots.loading && <Loading />}{bots.data?.map(bot => <Toggle key={bot.id} label={bot.name} hint={`${bot.sidebar.hidden ? 'Hidden — OS alerts suppressed. ' : ''}Work continues regardless of notification preferences.`} checked={bot.sidebar.notificationsEnabled} disabled={intent.disabled} onChange={notificationsEnabled => void (async () => { const saved = await intent.run(() => client.call('PATCH /bots/:id/sidebar', { params: { id: bot.id }, body: { notificationsEnabled, revision: bot.revision, clientNonce: nonce() } })); if (saved) { bots.setData(previous => previous?.map(value => value.id === saved.id ? saved : value)); await refresh(); } })()} />)}{bots.data?.length === 0 && <p>No visible Bots.</p>}<p className="small muted">Workspace {snapshot.workspace.name}; settings apply to your account only.</p></section></div>;
}
function PreferenceEditor({ value, disabled, onSave }: { value: NotificationPreferences; disabled: boolean; onSave: (value: NotificationPreferences) => Promise<void> }) {
  const [preferences, setPreferences] = useState(value);
  const labels: Record<keyof NotificationPreferences, string> = { enabled: 'Enable notifications', sound: 'Notification sounds', previews: 'Include privacy-safe message previews', completed: 'Completed work', needsInput: 'Needs your input' };
  return <form className="panel stack" onSubmit={e => { e.preventDefault(); void onSave(preferences); }}><h2>Notification preferences</h2>{(Object.keys(labels) as (keyof NotificationPreferences)[]).map(key => <Toggle key={key} label={labels[key]} checked={preferences[key]} disabled={disabled} onChange={value => setPreferences({ ...preferences, [key]: value })} />)}<button className="primary" disabled={disabled}>Save notifications</button></form>;
}
