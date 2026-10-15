import { useState } from 'react';
import { LemonBotError, nonce, type User, type Preferences, type Confirmation, type Device, type AuthSession, type ReauthResult } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { useQuery, Field, ErrorNotice, Loading, ConfirmDialog, formatTime } from '../../ui';
import { allPages, useIntent, IntentNotice, Toggle, NarrowConfirm } from './shared';
import { AccountReauthentication } from './reauth';
import { AccountAvatar } from './avatar';
import { persistCleanupHandoff, type CleanupHandoff } from '../../cleanup-handoff';

export function AccountSettings() {
  const { client, refresh, logout, snapshot } = useApp();
  const me = useQuery('settings:me', () => client.call('GET /me'));
  const sessions = useQuery('settings:sessions', () => allPages(cursor => client.call('GET /auth/sessions', { query: { cursor, limit: 200 } })));
  const devices = useQuery('settings:devices', () => allPages(cursor => client.call('GET /devices', { query: { cursor, limit: 200 } })));
  const intent = useIntent(async () => { await Promise.all([me.reload(), sessions.reload(), devices.reload(), refresh()]); });
  const [deletion, setDeletion] = useState<Confirmation>();
  const [reauthPassword, setReauthPassword] = useState('');
  const [oidcReauth, setOidcReauth] = useState<ReauthResult>();
  const [revoke, setRevoke] = useState<{ kind: 'device'; value: Device } | { kind: 'session'; value: AuthSession }>();
  return <div className="stack"><IntentNotice intent={intent} /><ErrorNotice error={me.error} />{me.loading && !me.data && <Loading />}{me.data && <AccountEditor key={me.data.id} user={me.data} onSave={async body => {
    const saved = await intent.run(() => client.call('PATCH /me', { body: { ...body, preferences: { ...body.preferences, voice: me.data!.preferences.voice }, revision: me.data!.revision, clientNonce: nonce() } }));
    if (saved) { me.setData(saved); await refresh(); }
    return !!saved;
  }} disabled={intent.disabled} onUpload={async file => {
    const uploaded = await intent.run(() => client.upload(file, { purpose: 'avatar', clientNonce: nonce() }, file.name));
    return uploaded?.id;
  }} />}
  <PasswordEditor disabled={intent.disabled} onSave={async (currentPassword, newPassword) => {
    const result = await intent.run(() => client.call('PUT /me/password', { body: { currentPassword, newPassword, clientNonce: nonce() } }));
    if (result) await sessions.reload();
    return !!result;
  }} />
  <section className="panel stack"><h2>Sessions & devices</h2><p className="muted">Password changes revoke other sessions. Device removal revokes that installation’s sessions and disables delivery; it does not erase files on that device.</p><ErrorNotice error={sessions.error} /><ErrorNotice error={devices.error} />{(sessions.loading || devices.loading) && <Loading />}<h3>Signed-in sessions</h3><ul className="list">{sessions.data?.map(session => <li className="list-row" key={session.id}><div><strong>{session.current ? 'This session' : 'Session'}</strong><div className="small muted">{session.id} · Device {session.deviceId ?? 'not registered'}<br />Last seen {formatTime(session.lastSeenAtMs)} · {session.expiresAtMs === null ? 'Until revoked' : `Expires ${formatTime(session.expiresAtMs)}`}</div></div><button disabled={intent.disabled} onClick={() => session.current ? void intent.run(logout) : setRevoke({ kind: 'session', value: session })}>{session.current ? 'Sign out' : 'Revoke session'}</button></li>)}</ul>{sessions.data?.length === 0 && <p>No sessions returned.</p>}<h3>Registered devices</h3><ul className="list">{devices.data?.map(device => <DeviceRow key={device.id} device={device} disabled={intent.disabled} onRename={async name => {
    const updated = await intent.run(() => client.call('PATCH /devices/:id', { params: { id: device.id }, body: { name, revision: device.revision, clientNonce: nonce() } }));
    if (updated) await devices.reload();
  }} onRemove={() => setRevoke({ kind: 'device', value: device })} />)}</ul>{devices.data?.length === 0 && <p>No devices registered.</p>}
  {revoke && <NarrowConfirm title={`Revoke ${revoke.kind}`} busy={intent.disabled} onCancel={() => setRevoke(undefined)} onConfirm={() => void (async () => {
    const result = await intent.run(() => revoke.kind === 'device' ? client.call('DELETE /devices/:id', { params: { id: revoke.value.id }, body: { clientNonce: nonce() } }) : client.call('DELETE /auth/sessions/:id', { params: { id: revoke.value.id }, body: { clientNonce: nonce() } }));
    if (result) { setRevoke(undefined); await Promise.all([sessions.reload(), devices.reload()]); }
  })()}><p>Revoke exactly {revoke.value.id}? This session loses access; revoking a device also revokes its device-bound sessions and notification delivery.</p></NarrowConfirm>}
  </section>
  <section className="panel stack"><h2>Account access</h2><p>Sign out of this browser. Your other saved accounts stay on this device.</p><button disabled={intent.disabled} onClick={() => void intent.run(logout)}>Sign out</button></section>
  <section className="panel stack"><h3>Deleted account cleanup</h3><p>If you delete your account, your workspace owner can check what was cleaned up. Files on your computers and accounts with other services are separate.</p><details><summary>Details for your workspace owner</summary><p>Account reference: <code>{snapshot.user.id}</code></p><button onClick={() => void navigator.clipboard.writeText(snapshot.user.id)}>Copy reference</button></details></section>
  <section className="panel stack"><h2>Delete account</h2><p>Deleting your account signs you out everywhere and removes the personal Lemon Bot data listed in the next step. It does not delete files on your computers, browser logins, provider accounts or backups. Cleanup at other services may take longer.</p><h3>Confirm it’s you</h3><p>Enter your password, or sign in with your identity provider.</p><Field label="Current password"><input type="password" autoComplete="current-password" value={reauthPassword} onChange={e => setReauthPassword(e.target.value)}/></Field><AccountReauthentication onReauthenticated={setOidcReauth}/>{oidcReauth && <p role="status">Identity confirmed until {formatTime(oidcReauth.expiresAtMs)}.</p>}<button className="danger" disabled={intent.disabled || (!reauthPassword && (!oidcReauth || Date.now() >= oidcReauth.expiresAtMs))} onClick={() => void (async () => { const preview = await intent.run(() => client.call('POST /me/preview', { body: { action: 'delete', clientNonce: nonce() } })); if (preview) setDeletion(preview); })()}>Review account deletion</button></section>
  {deletion && <ConfirmDialog title="Delete account everywhere" confirmation={deletion} disabled={intent.disabled} onCancel={() => { setDeletion(undefined); setReauthPassword(''); }} onConfirm={async confirm => {
    const result = await intent.run(async () => {
      const reauth = oidcReauth && oidcReauth.expiresAtMs > Date.now() ? oidcReauth : await client.call('POST /auth/reauth', { body: { password: reauthPassword } });
      setReauthPassword(''); setOidcReauth(undefined);
      const clientNonce = nonce();
      const handoff: CleanupHandoff = { backendUrl: client.baseUrl, workspaceId: snapshot.workspace.id, userId: snapshot.user.id, clientNonce, requestedAtMs: Date.now(), status: 'prepared' };
      persistCleanupHandoff(handoff);
      try {
        const deleted = await client.call('DELETE /me', { body: { ...confirm, reauthToken: reauth.reauthToken, clientNonce } });
        persistCleanupHandoff({ ...handoff, status: 'product_delete_acknowledged' });
        return deleted;
      } catch (failure) {
        const teardownId = failure instanceof LemonBotError ? failure.details?.teardownId : undefined;
        persistCleanupHandoff({ ...handoff, status: failure instanceof LemonBotError && !failure.outcomeUnknown && failure.retrySafe ? 'refused' : 'outcome_unknown',
          ...(typeof teardownId === 'string' ? { teardownId } : {}),
          ...(failure instanceof LemonBotError ? { requestId: failure.requestId, errorCode: failure.code } : {}) });
        throw failure;
      }
    });
    if (result) { setDeletion(undefined); await logout(); }
  }} />}
  </div>;
}

function AccountEditor({ user, onSave, onUpload, disabled }: { user: User; onSave: (body: { displayName: string; email: string; avatarAttachmentId: string | null; preferences: Preferences }) => Promise<boolean>; onUpload: (file: File) => Promise<string | undefined>; disabled: boolean }) {
  const [displayName, setDisplayName] = useState(user.displayName);
  const [email, setEmail] = useState(user.email);
  const [avatar, setAvatar] = useState(user.avatarAttachmentId);
  const [preferences, setPreferences] = useState(user.preferences);
  const [saved, setSaved] = useState(false);
  return <form className="panel stack" onChange={() => setSaved(false)} onSubmit={e => { e.preventDefault(); void onSave({ displayName, email, avatarAttachmentId: avatar, preferences }).then(ok => setSaved(ok)); }}><h2>Profile & preferences</h2><AccountAvatar attachmentId={avatar} /><fieldset disabled={disabled} className="stack"><div className="grid"><Field label="Display name"><input required maxLength={120} value={displayName} onChange={e => setDisplayName(e.target.value)} /></Field><Field label="Email"><input type="email" required value={email} onChange={e => setEmail(e.target.value)} /></Field></div><Field label="Avatar image" hint="PNG, JPEG or WebP. Uploaded image is associated only when you save."><input type="file" accept="image/png,image/jpeg,image/webp" onChange={e => { const file = e.target.files?.[0]; if (file) void onUpload(file).then(id => { if (id) setAvatar(id); }); }} /></Field>{avatar && <div className="row"><span className="small">Avatar attachment {avatar}</span><button type="button" onClick={() => setAvatar(null)}>Remove avatar</button></div>}<div className="grid"><Field label="Appearance"><select value={preferences.appearance} onChange={e => setPreferences({ ...preferences, appearance: e.target.value as Preferences['appearance'] })}><option value="system">System</option><option value="light">Light</option><option value="dark">Dark</option></select></Field><Field label="Language (BCP-47)" hint="Blank uses automatic language selection."><input value={preferences.language ?? ''} onChange={e => setPreferences({ ...preferences, language: e.target.value || null })} /></Field><Field label="Timezone (IANA)"><input required value={preferences.timezone} onChange={e => setPreferences({ ...preferences, timezone: e.target.value })} /></Field></div><Toggle label="Bot colors" checked={preferences.botColors} onChange={botColors => setPreferences({ ...preferences, botColors })} /><Toggle label="Threads beside chat" checked={preferences.threadsBesideChat} onChange={threadsBesideChat => setPreferences({ ...preferences, threadsBesideChat })} /><Toggle label="Milestone celebrations" checked={preferences.celebrationsEnabled} onChange={celebrationsEnabled => setPreferences({ ...preferences, celebrationsEnabled })} /><button className="primary" type="submit">Save profile & preferences</button></fieldset>{saved && <p role="status" className="muted">Profile and preferences saved.</p>}</form>;
}
function PasswordEditor({ onSave, disabled }: { onSave: (current: string, next: string) => Promise<boolean>; disabled: boolean }) {
  const [current, setCurrent] = useState(''); const [next, setNext] = useState(''); const [confirmation, setConfirmation] = useState(''); const [saved, setSaved] = useState(false);
  return <form className="panel stack" onSubmit={e => { e.preventDefault(); void onSave(current, next).then(ok => { if (ok) { setCurrent(''); setNext(''); setConfirmation(''); setSaved(true); } }); }}><h2>Password</h2><fieldset className="grid" disabled={disabled}><Field label="Current password"><input required type="password" autoComplete="current-password" value={current} onChange={e => setCurrent(e.target.value)} /></Field><Field label="New password (12–1024 UTF-8 bytes)"><input required type="password" autoComplete="new-password" minLength={12} value={next} onChange={e => setNext(e.target.value)} /></Field><Field label="Confirm new password"><input required type="password" autoComplete="new-password" value={confirmation} onChange={e => setConfirmation(e.target.value)} /></Field></fieldset>{confirmation && next !== confirmation && <p role="alert">Passwords do not match.</p>}<button className="primary" disabled={disabled || !current || next !== confirmation || new TextEncoder().encode(next).length < 12 || new TextEncoder().encode(next).length > 1024}>Change password & revoke other sessions</button>{saved && <p role="status">Password changed.</p>}</form>;
}
function DeviceRow({ device, disabled, onRename, onRemove }: { device: Device; disabled: boolean; onRename: (name: string) => Promise<void>; onRemove: () => void }) {
  const [name, setName] = useState(device.name);
  return <li className="list-row"><div className="stack"><label>Device name<input value={name} maxLength={120} onChange={e => setName(e.target.value)} disabled={disabled} /></label><span className="muted small">{device.platform} · {device.appVersion} · Push {device.pushEnabled ? 'enabled' : 'disabled'} · Last seen {formatTime(device.lastSeenAtMs)} · {device.id}</span></div><div className="row"><button disabled={disabled || !name.trim() || name === device.name} onClick={() => void onRename(name)}>Rename</button><button className="danger" disabled={disabled} onClick={onRemove}>Remove device</button></div></li>;
}
