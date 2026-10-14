import { useEffect, useRef, useState } from 'react';
import { LemonBotClient, nonce, type OIDCProvider, type ReauthResult, type SCIMResourceType, type SCIMSchema, type SCIMServiceProviderConfig } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { ErrorNotice, useAction, Badge, EmptyState, Field, formatTime, safeExternal, useQuery } from '../../ui';
import { AccessNotice, Checks, DeleteButton, IntentNotice, QueryNotice, Toggle, useCollection, useIntent, words } from './shared';

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
  const [groupClaim, setGroupClaim] = useState(provider?.groupClaim ?? '');
  const [requireSSO, setRequireSSO] = useState(provider?.requireSSO ?? false);
  const [enabled, setEnabled] = useState(provider?.enabled ?? true);
  return <form className="panel stack" onSubmit={event => { event.preventDefault(); void intent.perform(() => provider ? client.call('PATCH /admin/oidc/providers/:id', { params: { id: provider.id }, body: { clientNonce: nonce(), revision: provider.revision, enabled, requireSSO, scopes: words(scopeText), allowedEmailDomains: words(domainText) } }) : client.call('POST /admin/oidc/providers', { body: { clientNonce: nonce(), name, issuer, clientId, clientSecretRef: secretRef, scopes: words(scopeText), allowedEmailDomains: words(domainText), requireSSO, ...(groupClaim.trim() ? { groupClaim: groupClaim.trim() } : {}) } })).then(result => { if (result) { onClose(); void onSaved().catch(reportError); } }); }}>
    <h2>{provider ? `Edit ${provider.name}` : 'Register OIDC provider'}</h2><p className="muted">Requires a confidential client, approved HTTPS discovery/JWKS/token origins, and an operator-configured server secret reference. No raw client secrets. Immutable issuer, client and claim configuration require an explicitly reviewed replacement provider.</p>
    <fieldset disabled={Boolean(provider)} className="grid"><Field label="Provider name"><input required maxLength={120} value={name} onChange={event => setName(event.target.value)} /></Field><Field label="HTTPS issuer"><input type="url" required value={issuer} onChange={event => setIssuer(event.target.value)} /></Field><Field label="Client ID"><input required value={clientId} onChange={event => setClientId(event.target.value)} /></Field><Field label="Server client secret reference"><input required value={secretRef} onChange={event => setSecretRef(event.target.value)} /></Field><Field label="Directory group claim" hint="Only preconfigured directory external IDs map to groups. Claims cannot grant arbitrary roles."><input value={groupClaim} onChange={event => setGroupClaim(event.target.value)} /></Field></fieldset>
    <Field label="OIDC scopes (comma-separated)"><input required value={scopeText} onChange={event => setScopeText(event.target.value)} /></Field><Field label="Allowed email domains (comma-separated)"><input value={domainText} onChange={event => setDomainText(event.target.value)} /></Field><Toggle checked={requireSSO} onChange={setRequireSSO}>Require SSO for managed identities</Toggle>{provider && <Toggle checked={enabled} onChange={setEnabled}>Provider enabled</Toggle>}<p className="small muted">Disabling a provider does not unlock local login. Operator break-glass owner configuration is separate.</p><IntentNotice intent={intent} reconcile={onSaved} /><div className="row"><button className="primary" disabled={intent.disabled}>Save provider</button><button type="button" onClick={onClose}>Close</button></div>
  </form>;
}

interface Discovery { service: SCIMServiceProviderConfig; resources: SCIMResourceType[]; schemas: SCIMSchema[] }
function IdentityAdmin() {
  const { client, reportError } = useApp();
  const providers = useCollection('admin-oidc-providers', query => client.call('GET /admin/oidc/providers', { query }));
  const tokens = useCollection('identity-integration-tokens', query => client.call('GET /integration-tokens', { query }));
  const groups = useCollection('identity-directory-mappings', query => client.call('GET /directory/groups', { query }));
  const [editing, setEditing] = useState<OIDCProvider | 'new' | null>(null);
  const [tokenName, setTokenName] = useState('');
  const [scopes, setScopes] = useState(['scim.users', 'scim.groups']);
  const [expiryDays, setExpiryDays] = useState('');
  const [issued, setIssued] = useState<string>();
  const [discoveryToken, setDiscoveryToken] = useState('');
  const [discovery, setDiscovery] = useState<Discovery>();
  const intent = useIntent();
  const readIntent = useAction();
  const base = client.baseUrl.replace(/\/$/, '');
  return <><section className="panel stack"><div className="row spread"><h2>OIDC providers</h2><button type="button" disabled={intent.disabled} onClick={() => setEditing('new')}>Register provider</button></div><QueryNotice query={providers} /><QueryNotice query={groups} /><IntentNotice intent={intent} reconcile={async () => { await providers.reload(); await tokens.reload(); }} />{providers.data?.length === 0 && <EmptyState title="No configured OIDC providers" />}{providers.data?.map(provider => <article className="card stack" key={provider.id}><div className="row spread"><h3>{provider.name}</h3><Badge>{provider.enabled ? 'enabled' : 'disabled'}</Badge></div><dl className="enterprise-facts"><dt>Issuer</dt><dd>{provider.issuer}</dd><dt>Client ID</dt><dd>{provider.clientId}</dd><dt>Server secret reference</dt><dd>{provider.clientSecretRef}</dd><dt>Scopes</dt><dd>{provider.scopes.join(', ')}</dd><dt>Managed domains</dt><dd>{provider.allowedEmailDomains.join(', ') || 'None configured'}</dd><dt>Require SSO</dt><dd>{provider.requireSSO ? 'Yes' : 'No'}</dd><dt>Group claim</dt><dd>{provider.groupClaim ?? 'None configured'}</dd><dt>Registered backend callback</dt><dd><code>{base}/auth/oidc/callback/{encodeURIComponent(provider.id)}</code></dd><dt>External end-session endpoint</dt><dd>{provider.endSessionEndpoint ?? 'Not configured; product token revocation remains immediate'}</dd></dl><div className="row"><button type="button" onClick={() => setEditing(provider)}>Edit provider policy</button><DeleteButton name={provider.name} disabled={intent.disabled} onDelete={() => void intent.perform(() => client.call('DELETE /admin/oidc/providers/:id', { params: { id: provider.id }, body: { revision: provider.revision, clientNonce: nonce() } })).then(result => { if (result) void providers.reload().catch(reportError); })} /></div></article>)}
      <h3>Preconfigured directory group mappings</h3><p className="small muted">Verified claim values match these external IDs only. Source-managed memberships are edited at the provider, not overwritten locally.</p>{groups.data?.map(group => <p key={group.id}>{group.name} · {group.source} · external ID <code>{group.externalId ?? 'none (local)'}</code></p>)}
    </section>{editing && <ProviderEditor key={editing === 'new' ? 'new' : editing.id} provider={editing === 'new' ? undefined : editing} onSaved={providers.reload} onClose={() => setEditing(null)} />}
    <section className="panel stack"><h2>SCIM provisioning tokens</h2><p className="muted">Owner-issued scoped bearer tokens are shown once. They cannot call product chats or administration. Deprovisioning revokes product sessions immediately without deleting host files.</p><QueryNotice query={tokens} /><form className="stack" onSubmit={event => { event.preventDefault(); void intent.perform(() => client.call('POST /integration-tokens', { body: { clientNonce: nonce(), name: tokenName, kind: 'scim', scopes, ...(expiryDays ? { expiresInMs: Number(expiryDays) * 86_400_000 } : {}) } })).then(result => { if (result) { setIssued(result.token); setTokenName(''); void tokens.reload().catch(reportError); } }); }}><Field label="Integration name"><input required maxLength={120} value={tokenName} onChange={event => setTokenName(event.target.value)} /></Field><Checks legend="Provisioning scopes" options={[{ id: 'scim.users', name: 'Provision users' }, { id: 'scim.groups', name: 'Provision directory groups' }]} value={scopes} onChange={setScopes} /><Field label="Expiry in days (blank for no expiry)"><input type="number" min="1" step="1" value={expiryDays} onChange={event => setExpiryDays(event.target.value)} /></Field><button className="primary" disabled={intent.disabled || !scopes.length || Boolean(issued)}>Issue SCIM token once</button></form>
      {issued && <aside className="card stack"><h3>Copy this token now</h3><p>It will not be returned again. Treat it as a secret. Dismiss to erase it from this screen.</p><output className="enterprise-secret">{issued}</output><div className="row"><button type="button" onClick={() => void navigator.clipboard.writeText(issued).catch(reportError)}>Copy token</button><button type="button" onClick={() => setIssued(undefined)}>Dismiss and erase</button></div></aside>}
      {tokens.data?.filter(token => token.kind === 'scim').map(token => <article className="list-row" key={token.id}><div><strong>{token.name}</strong><p className="small muted">{token.scopes.join(', ')} · expires {token.expiresAtMs === null ? 'never' : formatTime(token.expiresAtMs)}</p></div><button type="button" className="danger" disabled={intent.disabled} onClick={() => { if (!window.confirm(`Revoke SCIM token ${token.name}? Its provisioning requests will stop immediately.`)) return; void intent.perform(() => client.call('DELETE /integration-tokens/:id', { params: { id: token.id }, body: { revision: token.revision, clientNonce: nonce() } })).then(result => { if (result) void tokens.reload().catch(reportError); }); }}>Revoke token</button></article>)}
      <h3>Exact SCIM integration URLs</h3><dl className="enterprise-facts">{['', '/ServiceProviderConfig', '/ResourceTypes', '/Schemas', '/Users', '/Groups'].map(path => <div key={path}><dt>{path.slice(1) || 'SCIM base'}</dt><dd><code>{base}/scim/v2{path}</code></dd></div>)}</dl><p className="small muted">application/scim+json · Bearer scoped integration token · existing updates/deletes require If-Match with the returned strong ETag. Bulk and sort are not supported.</p>
      <form className="row" onSubmit={event => { event.preventDefault(); const token = issued ?? discoveryToken; setDiscoveryToken(''); void readIntent.run(async () => { const scim = new LemonBotClient({ baseUrl: client.baseUrl, token }); const service = await scim.call('GET /scim/v2/ServiceProviderConfig'); const resources = await scim.call('GET /scim/v2/ResourceTypes'); const schemas = await scim.call('GET /scim/v2/Schemas'); const result = { service, resources: resources.Resources, schemas: schemas.Resources }; setDiscovery(result); return result; }); }}><Field label="SCIM token for live discovery" hint={issued ? 'Uses the just-issued token held only in this screen.' : 'Token is erased from the input before the request; never stored.'}><input type="password" autoComplete="off" required={!issued} disabled={Boolean(issued)} value={discoveryToken} onChange={event => setDiscoveryToken(event.target.value)} /></Field><button disabled={readIntent.busy}>Load actual discovery</button></form><ErrorNotice error={readIntent.error} />{discovery && <div className="card"><h4>Measured discovery</h4><p>PATCH {discovery.service.patch.supported ? 'supported' : 'unsupported'} · filtering {discovery.service.filter.supported ? 'supported' : 'unsupported'} (maximum {discovery.service.filter.maxResults}) · bulk {discovery.service.bulk.supported ? 'supported' : 'unsupported'} · ETags {discovery.service.etag.supported ? 'supported' : 'unsupported'}</p>{discovery.resources.map(resource => <p key={resource.id}>{resource.name} · <code>{resource.endpoint}</code> · {resource.schema}</p>)}{discovery.schemas.map(schema => <details key={schema.id}><summary>{schema.name}</summary><p>{schema.description}</p><p><code>{schema.id}</code></p><ul>{schema.attributes.map((attribute, index) => <li key={index}>{typeof attribute.name === 'string' ? attribute.name : 'Unnamed attribute'} · {typeof attribute.type === 'string' ? attribute.type : 'type not supplied'}{attribute.required === true ? ' · required' : ''}</li>)}</ul></details>)}</div>}
    </section></>;
}

export function IdentityScreen() {
  const { snapshot } = useApp();
  return <div className="stack"><OwnIdentities />{snapshot.member.role === 'owner' ? <IdentityAdmin /> : <AccessNotice owner />}</div>;
}
