import { useState } from 'react';
import { nonce, type OIDCFlow, type ReauthResult } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { useQuery, ErrorNotice, Field, formatTime } from '../../ui';
import { useIntent, IntentNotice } from './shared';

interface PendingReauth { flowId: string; verifier: string; expiresAtMs: number }
export function AccountReauthentication({ onReauthenticated }: { onReauthenticated: (result: ReauthResult) => void }) {
  const { client, snapshot, device } = useApp();
  const providers = useQuery('settings:account-reauth-providers', () => client.call('GET /auth/oidc/providers'));
  const key = `lemonbot.reauth:${snapshot.workspace.id}:${snapshot.user.id}`;
  const [providerId, setProviderId] = useState('');
  const [pending, setPending] = useState<PendingReauth | null>(() => {
    try { const raw = sessionStorage.getItem(key); if (!raw) return null; const value: unknown = JSON.parse(raw); if (typeof value !== 'object' || value === null || !('flowId' in value) || !('verifier' in value) || !('expiresAtMs' in value) || typeof value.flowId !== 'string' || typeof value.verifier !== 'string' || typeof value.expiresAtMs !== 'number') return null; return { flowId: value.flowId, verifier: value.verifier, expiresAtMs: value.expiresAtMs }; } catch { return null; }
  });
  const [flow, setFlow] = useState<OIDCFlow>();
  const [completionCode, setCompletionCode] = useState(() => new URLSearchParams(window.location.search).get('completionCode') ?? '');
  const callbackFlowId = new URLSearchParams(window.location.search).get('flowId');
  const intent = useIntent(async () => { await providers.reload(); });
  async function start() {
    if (!providerId) return;
    await intent.run(async () => {
      const verifier = nonce() + nonce();
      const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier)));
      const challenge = btoa(String.fromCharCode(...digest)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
      const redirect = new URL('/', window.location.origin); redirect.searchParams.set('screen', 'settings.account');
      const result = await client.call('POST /auth/oidc/start', { body: { providerId, purpose: 'reauth', redirectUri: redirect.toString(), codeChallenge: challenge, ...(device ? { deviceId: device.id } : {}), clientNonce: nonce() } });
      const next = { flowId: result.id, verifier, expiresAtMs: result.expiresAtMs };
      sessionStorage.setItem(key, JSON.stringify(next)); setPending(next); setFlow(result);
    });
  }
  function cancel() {
    setPending(null); setFlow(undefined); setCompletionCode(''); sessionStorage.removeItem(key);
    const url = new URL(window.location.href); url.searchParams.delete('completionCode'); url.searchParams.delete('flowId'); window.history.replaceState(null, '', url);
  }
  return <section className="card stack"><h3>SSO reauthentication for deletion</h3><p className="muted small">Use your linked configured identity provider. The verifier is temporarily stored in this tab, bound to your account; the single-use reauthentication token remains in memory only. The redirect must be allowlisted by your operator.</p><ErrorNotice error={providers.error} /><IntentNotice intent={intent} /><Field label="Identity provider"><select value={providerId} disabled={intent.disabled} onChange={e => setProviderId(e.target.value)}><option value="">Select configured provider</option>{providers.data?.filter(provider => provider.enabled).map(provider => <option value={provider.id} key={provider.id}>{provider.name}</option>)}</select></Field><button disabled={intent.disabled || !providerId} onClick={() => void start()}>Prepare identity reauthentication</button>{flow && <button disabled={Date.now() >= flow.expiresAtMs} onClick={() => { const url = new URL(flow.authorizationUrl); if (url.protocol !== 'https:' && !(url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname))) return; window.location.assign(url.toString()); }}>Continue to identity provider</button>}{pending && <><p className="small">Flow {pending.flowId} · Expires {formatTime(pending.expiresAtMs)}. Return here from the provider; completion is explicit and never automatically retried.</p>{completionCode && <button className="primary" disabled={intent.disabled || callbackFlowId !== pending.flowId || Date.now() >= pending.expiresAtMs} onClick={() => void (async () => { const result = await intent.run(() => client.call('POST /auth/oidc/complete', { body: { flowId: pending.flowId, completionCode, codeVerifier: pending.verifier, ...(device ? { deviceId: device.id } : {}), clientNonce: nonce() } })); if (result && 'reauthToken' in result) { onReauthenticated(result); cancel(); } })()}>Complete single-use reauthentication</button>}{completionCode && callbackFlowId !== pending.flowId && <p role="alert">Callback flow does not match this tab/account. No credential exchange was attempted.</p>}<button onClick={cancel}>Discard reauthentication flow</button></>}{providers.data?.length === 0 && <p>No configured identity providers; use password reauthentication.</p>}</section>;
}
