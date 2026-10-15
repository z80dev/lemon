import { useEffect, useRef, useState } from 'react';
import { nonce, type OIDCProvider, type ReauthResult } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { Badge, EmptyState, Field, formatTime, safeExternal, useQuery } from '../../ui';
import { AccessNotice, DeleteButton, IntentNotice, QueryNotice, Toggle, useCollection, useIntent, words } from './shared';

interface PendingIdentityFlow { flowId: string; verifier: string; purpose: 'reauth' | 'link'; userId: string; expiresAtMs: number; reauthToken?: string }
const encode = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
async function pkce() {
  const verifier = encode(crypto.getRandomValues(new Uint8Array(32)));
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  return { verifier, challenge: encode(new Uint8Array(digest)) };
}
function pendingFlow(raw: string | null): PendingIdentityFlow | undefined {
  if (!raw) return;
  const value: unknown = JSON.parse(raw);
  if (!value || typeof value !== 'object') return;
  const data = value as Record<string, unknown>;
  if (typeof data.flowId !== 'string' || typeof data.verifier !== 'string' || typeof data.userId !== 'string' || typeof data.expiresAtMs !== 'number' || (data.purpose !== 'link' && data.purpose !== 'reauth')) return;
  if (data.purpose === 'link' && typeof data.reauthToken !== 'string') return;
  return data as unknown as PendingIdentityFlow;
}

function OwnIdentities() {
  const { client, snapshot, device, reportError } = useApp();
  const identities = useCollection('own-identity-links', query => client.call('GET /auth/identities', { query }));
  const providers = useQuery('identity-public-providers', () => client.call('GET /auth/oidc/providers'));
  const intent = useIntent();
  const [password, setPassword] = useState('');
  const [reauth, setReauth] = useState<ReauthResult>();
  const [providerId, setProviderId] = useState('');
  const handled = useRef(false);
  const key = `lemonbot.identity-flow:${client.baseUrl}:${snapshot.user.id}`;
  useEffect(() => {
    if (handled.current) return;
    handled.current = true;
    const url = new URL(window.location.href);
    const flowId = url.searchParams.get('flowId');
    const completionCode = url.searchParams.get('completionCode');
    const failure = url.searchParams.get('error');
    if (!flowId && !completionCode && !failure) return;
    url.searchParams.delete('flowId'); url.searchParams.delete('completionCode'); url.searchParams.delete('error');
    window.history.replaceState(null, '', url);
    const raw = sessionStorage.getItem(key);
    // Consume local completion material before dispatch; never replay on remount.
    sessionStorage.removeItem(key);
    void intent.perform(async () => {
      const pending = pendingFlow(raw);
      if (failure) throw new Error('Identity provider did not complete authorization. No account identity has been accepted.');
      if (!pending || pending.userId !== snapshot.user.id || pending.flowId !== flowId || pending.expiresAtMs <= Date.now() || !completionCode) throw new Error('Identity flow is missing, expired or does not match this account. Start a new flow explicitly.');
      const body = { clientNonce: nonce(), flowId: pending.flowId, completionCode, codeVerifier: pending.verifier, ...(device ? { deviceId: device.id } : {}) };
      if (pending.purpose === 'link') {
        const result = await client.call('POST /auth/oidc/link', { body: { ...body, reauthToken: pending.reauthToken! } });
        await identities.reload();
        return result;
      }
      const result = await client.call('POST /auth/oidc/complete', { body });
      if (!('reauthToken' in result)) throw new Error('Provider returned a login result instead of account-bound reauthentication. This session has not been replaced.');
      setReauth(result);
      return result;
    });
  }, [client, device, identities, intent, key, snapshot.user.id]);

  async function start(purpose: 'link' | 'reauth') {
    await intent.perform(async () => {
      if (purpose === 'link' && (!reauth || reauth.expiresAtMs <= Date.now())) throw new Error('Reauthenticate your current account before linking a verified identity.');
      const proof = await pkce();
      const redirectUri = new URL('/?screen=settings.identity', window.location.origin).href;
      const flow = await client.call('POST /auth/oidc/start', { body: { clientNonce: nonce(), providerId, redirectUri, codeChallenge: proof.challenge, purpose, ...(device ? { deviceId: device.id } : {}) } });
      const authorizationUrl = safeExternal(flow.authorizationUrl);
      if (!authorizationUrl) throw new Error('Provider returned an unsafe authorization URL.');
      const pending: PendingIdentityFlow = { flowId: flow.id, verifier: proof.verifier, purpose, userId: snapshot.user.id, expiresAtMs: Math.min(flow.expiresAtMs, purpose === 'link' ? reauth!.expiresAtMs : flow.expiresAtMs), ...(purpose === 'link' ? { reauthToken: reauth!.reauthToken } : {}) };
      sessionStorage.setItem(key, JSON.stringify(pending));
      setReauth(undefined); setPassword('');
      window.location.assign(authorizationUrl);
      return flow;
    });
  }
  const authenticated = reauth && reauth.expiresAtMs > Date.now();
  return <section className="panel stack"><h2>Your verified identities</h2><p className="muted">Linking requires current-account reauthentication and a new verified PKCE provider flow, never an email match alone. Unlinking revokes associated product provider sessions immediately; external provider end-session is independently attempted and reported. Required SSO and the final permitted login method cannot be removed.</p><QueryNotice query={identities} /><QueryNotice query={providers} />
    {identities.data?.length === 0 && <EmptyState title="No linked provider identities" />}{identities.data?.map(identity => <article className="list-row" key={identity.id}><div><strong>{providers.data?.find(provider => provider.id === identity.providerId)?.name ?? identity.providerId}</strong><p className="small muted">{identity.issuer} · verified subject {identity.subject} · last used {formatTime(identity.lastUsedAtMs)}</p></div><button type="button" className="danger" disabled={intent.disabled || !authenticated} onClick={() => { if (!reauth || !window.confirm('Unlink this verified identity from your own account? Ensure you retain another permitted sign-in method.')) return; const token = reauth.reauthToken; setReauth(undefined); void intent.perform(() => client.call('DELETE /auth/identities/:id', { params: { id: identity.id }, body: { clientNonce: nonce(), revision: identity.revision, reauthToken: token } })).then(result => { if (result) void identities.reload().catch(reportError); }); }}>Unlink identity</button></article>)}
    <fieldset className="stack"><legend>Reauthenticate current account</legend><form className="row" onSubmit={event => { event.preventDefault(); const submitted = password; setPassword(''); void intent.perform(() => client.call('POST /auth/reauth', { body: { password: submitted } })).then(result => { if (result) setReauth(result); }); }}><Field label="Current password"><input type="password" autoComplete="current-password" required value={password} onChange={event => setPassword(event.target.value)} /></Field><button disabled={intent.disabled}>Verify password</button></form><Field label="Identity provider"><select required value={providerId} onChange={event => setProviderId(event.target.value)}><option value="">Choose configured provider</option>{providers.data?.filter(provider => provider.enabled).map(provider => <option key={provider.id} value={provider.id}>{provider.name}{provider.requireSSO ? ' · SSO required' : ''}</option>)}</select></Field><div className="row"><button type="button" disabled={intent.disabled || !providerId} onClick={() => void start('reauth')}>Reauthenticate with provider</button><button type="button" className="primary" disabled={intent.disabled || !providerId || !authenticated} onClick={() => void start('link')}>Link verified identity</button></div>{reauth && <p role="status">Reauthentication valid until {formatTime(reauth.expiresAtMs)}. One use; not a new sign-in session.</p>}</fieldset><IntentNotice intent={intent} reconcile={identities.reload} />
  </section>;
}

function ProviderEditor({ provider, onSaved, onClose }: { provider?: OIDCProvider; onSaved: () => Promise<void>; onClose: () => void }) {
  const { client, reportError } = useApp();
  const intent = useIntent();
  const [name, setName] = useState(provider?.name ?? '');
  const [issuer, setIssuer] = useState(provider?.issuer ?? '');
  const [clientId, setClientId] = useState(provider?.clientId ?? '');
  const [secretRef, setSecretRef] = useState(provider?.clientSecretRef ?? '');
  const [scopeText, setScopeText] = useState(provider?.scopes.join(', ') ?? 'openid, profile, email');
  const [domainText, setDomainText] = useState(provider?.allowedEmailDomains.join(', ') ?? '');
  const [requireSSO, setRequireSSO] = useState(provider?.requireSSO ?? false);
  const [enabled, setEnabled] = useState(provider?.enabled ?? true);
  return <form className="panel stack" onSubmit={event => { event.preventDefault(); void intent.perform(() => provider ? client.call('PATCH /admin/oidc/providers/:id', { params: { id: provider.id }, body: { clientNonce: nonce(), revision: provider.revision, enabled, requireSSO, scopes: words(scopeText), allowedEmailDomains: words(domainText) } }) : client.call('POST /admin/oidc/providers', { body: { clientNonce: nonce(), name, issuer, clientId, clientSecretRef: secretRef, scopes: words(scopeText), allowedEmailDomains: words(domainText), requireSSO } })).then(result => { if (result) { onClose(); void onSaved().catch(reportError); } }); }}>
    <h2>{provider ? `Edit ${provider.name}` : 'Register OIDC provider'}</h2><p className="muted">Requires a confidential client, approved HTTPS discovery/JWKS/token origins, and an operator-configured server secret reference. No raw client secrets. Immutable issuer, client and claim configuration require an explicitly reviewed replacement provider.</p>
    <fieldset disabled={Boolean(provider)} className="grid"><Field label="Provider name"><input required maxLength={120} value={name} onChange={event => setName(event.target.value)} /></Field><Field label="HTTPS issuer"><input type="url" required value={issuer} onChange={event => setIssuer(event.target.value)} /></Field><Field label="Client ID"><input required value={clientId} onChange={event => setClientId(event.target.value)} /></Field><Field label="Server client secret reference"><input required value={secretRef} onChange={event => setSecretRef(event.target.value)} /></Field></fieldset>
    <Field label="OIDC scopes (comma-separated)"><input required value={scopeText} onChange={event => setScopeText(event.target.value)} /></Field><Field label="Allowed email domains (comma-separated)"><input value={domainText} onChange={event => setDomainText(event.target.value)} /></Field><Toggle checked={requireSSO} onChange={setRequireSSO}>Require SSO for managed identities</Toggle>{provider && <Toggle checked={enabled} onChange={setEnabled}>Provider enabled</Toggle>}<p className="small muted">Disabling a provider does not unlock local login. Operator break-glass owner configuration is separate.</p><IntentNotice intent={intent} reconcile={onSaved} /><div className="row"><button className="primary" disabled={intent.disabled}>Save provider</button><button type="button" onClick={onClose}>Close</button></div>
  </form>;
}

function IdentityAdmin() {
  const { client, reportError } = useApp();
  const providers = useCollection('owner-oidc-providers', query => client.call('GET /admin/oidc/providers', { query }));
  const [editing, setEditing] = useState<OIDCProvider | 'new' | null>(null);
  const intent = useIntent();
  return <div className="stack"><section className="panel stack"><div className="row spread"><h2>Optional sign-in providers</h2><button type="button" disabled={intent.disabled} onClick={() => setEditing('new')}>Register provider</button></div><p className="muted">Local owner sign-in does not require enterprise provisioning. A provider needs actual operator-configured secrets and allowlisted callback origins.</p><QueryNotice query={providers} /><IntentNotice intent={intent} reconcile={providers.reload} />{providers.data?.length === 0 && <EmptyState title="No configured OIDC providers" />}{providers.data?.map(provider => <article className="card stack" key={provider.id}><div className="row spread"><h3>{provider.name}</h3><Badge>{provider.enabled ? 'enabled' : 'disabled'}</Badge></div><dl className="enterprise-facts"><dt>Issuer</dt><dd>{provider.issuer}</dd><dt>Client ID</dt><dd>{provider.clientId}</dd><dt>Server secret reference</dt><dd>{provider.clientSecretRef}</dd><dt>Scopes</dt><dd>{provider.scopes.join(', ')}</dd><dt>Required SSO</dt><dd>{provider.requireSSO ? 'Yes' : 'No'}</dd></dl><div className="row"><button type="button" disabled={intent.disabled} onClick={() => setEditing(provider)}>Edit provider</button><DeleteButton name={provider.name} disabled={intent.disabled} error={intent.error} onDelete={() => intent.perform(() => client.call('DELETE /admin/oidc/providers/:id', { params: { id: provider.id }, body: { revision: provider.revision, clientNonce: nonce() } })).then(result => { if (result) void providers.reload().catch(reportError); return !!result; })} /></div></article>)}</section>{editing && <ProviderEditor key={editing === 'new' ? 'new' : editing.id} provider={editing === 'new' ? undefined : editing} onSaved={providers.reload} onClose={() => setEditing(null)} />}</div>;
}

export function IdentityScreen() {
  const { snapshot } = useApp();
  return <div className="stack"><OwnIdentities />{snapshot.workspace.ownerUserId === snapshot.user.id ? <IdentityAdmin /> : <AccessNotice owner />}</div>;
}
