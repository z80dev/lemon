import { useEffect, useState } from 'react';
import { LemonBotClient, nonce, type AuthResult } from '@lemon-bot/sdk';
import { ErrorNotice, Field, LemonFace, LemonMark, Loading, safeExternal, useAction, useQuery } from './ui';
import { CleanupHandoffCard } from './cleanup-handoff';

export interface SavedAccount { baseUrl: string; email: string; workspaceId?: string; workspaceName?: string }
export interface WebSession { baseUrl: string; token: string; email: string; workspaceId: string }
export function productUrl(value: string) {
  const url = new URL(value);
  const local = url.hostname === 'localhost' || url.hostname === '127.0.0.1' || url.hostname === '[::1]';
  if (url.username || url.password || url.search || url.hash || (!local && url.protocol !== 'https:') || !['http:', 'https:'].includes(url.protocol)) throw new Error('Use your product backend HTTPS URL (HTTP is allowed only on loopback). No credentials, query or fragment.');
  if (url.pathname !== '/' && url.pathname !== '/v1' && url.pathname !== '/v1/') throw new Error('Enter the product origin or its /v1 URL, not a Lemon controller URL.');
  return `${url.origin}/v1`;
}
export function savedAccounts(): SavedAccount[] {
  try { const value: unknown = JSON.parse(localStorage.getItem('lemonbot.accounts') || '[]'); return Array.isArray(value) ? value.filter((row): row is SavedAccount => !!row && typeof row === 'object' && 'baseUrl' in row && typeof row.baseUrl === 'string' && 'email' in row && typeof row.email === 'string') : []; } catch { return []; }
}
export function AuthScreen({ onAuth, initialBackend, notice }: { onAuth: (session: WebSession) => void; initialBackend?: string; notice?: string }) {
  const [baseUrl, setBaseUrl] = useState(initialBackend || `${location.origin}/v1`);
  const [backendInput, setBackendInput] = useState(baseUrl);
  const [backendError, setBackendError] = useState<unknown>();
  const [mode, setMode] = useState<'login' | 'setup'>('login');
  const [email, setEmail] = useState(''); const [password, setPassword] = useState('');
  const [displayName, setDisplayName] = useState(''); const [workspaceName, setWorkspaceName] = useState(''); const [setupCode, setSetupCode] = useState('');
  const [pendingOIDC, setPendingOIDC] = useState(false);
  const action = useAction(); const client = new LemonBotClient({ baseUrl });
  const setup = useQuery(`setup:${baseUrl}`, () => client.call('GET /setup'));
  const providers = useQuery(`oidc:${baseUrl}`, () => client.call('GET /auth/oidc/providers'));
  useEffect(() => { setMode(setup.data?.setupRequired ? 'setup' : 'login'); }, [setup.data?.setupRequired]);
  const finish = (result: AuthResult, backend = baseUrl) => {
    const accounts = savedAccounts().filter(account => !(account.baseUrl === backend && account.email === result.user.email));
    accounts.push({ baseUrl: backend, email: result.user.email, workspaceId: result.workspace.id, workspaceName: result.workspace.name });
    localStorage.setItem('lemonbot.accounts', JSON.stringify(accounts));
    const session = { baseUrl: backend, token: result.token, email: result.user.email, workspaceId: result.workspace.id };
    sessionStorage.setItem('lemonbot.session', JSON.stringify(session)); setPassword(''); setSetupCode(''); onAuth(session);
  };
  useEffect(() => {
    const query = new URLSearchParams(location.search);
    if (query.get('screen')?.startsWith('settings.') || !query.has('completionCode') || !query.has('flowId')) return;
    const raw = sessionStorage.getItem('lemonbot.oidc.login');
    if (!raw) { setBackendError(new Error('Sign-in didn’t finish. Start again from the sign-in button.')); return; }
    let pending: { baseUrl: string; flowId: string; verifier: string };
    try {
      const value: unknown = JSON.parse(raw);
      if (!value || typeof value !== 'object' || !('baseUrl' in value) || typeof value.baseUrl !== 'string' || !('flowId' in value) || typeof value.flowId !== 'string' || !value.flowId || !('verifier' in value) || typeof value.verifier !== 'string' || !value.verifier) throw new Error('Invalid stored sign-in flow.');
      pending = { baseUrl: productUrl(value.baseUrl), flowId: value.flowId, verifier: value.verifier };
      if (pending.flowId !== query.get('flowId')) throw new Error('Sign-in flow does not match this browser.');
    } catch {
      sessionStorage.removeItem('lemonbot.oidc.login');
      history.replaceState(null, '', location.pathname + location.hash);
      setBackendError(new Error('The saved sign-in flow is no longer usable. Start sign-in again.'));
      return;
    }
    const completionCode = query.get('completionCode')!;
    history.replaceState(null, '', location.pathname + location.hash); setPendingOIDC(true);
    void action.run(async () => {
      const result = await new LemonBotClient({ baseUrl: pending.baseUrl }).call('POST /auth/oidc/complete', { body: { clientNonce: nonce(), flowId: pending.flowId, completionCode, codeVerifier: pending.verifier } });
      if (!('token' in result)) throw new Error('Expected account sign-in, not a reauthentication result.');
      sessionStorage.removeItem('lemonbot.oidc.login'); finish(result, pending.baseUrl);
    }).finally(() => setPendingOIDC(false));
  }, []);
  return <main className="auth-layout"><section className="auth-story"><div className="brand"><LemonMark/> Lemon Bot</div><div><div className="eyebrow">Your personal assistant</div><h1>Your Bots.<br/>Your computers.</h1><p>Named assistants with focused jobs on computers you own. Your Bots keep working when you close this window.</p><div className="auth-companion" aria-hidden="true"><LemonFace size={128}/></div></div><p className="small">Your computers. Your accounts. Your choice.<br/>Bots on the same computer share that computer user’s files and sign-ins. Give Bots separate computers or user accounts when you need to keep their access apart.</p></section><section className="auth-form"><div className="auth-card stack">{notice && <p className="auth-session-notice" role="status" aria-live="polite">{notice}</p>}<div className="eyebrow">Connect to Lemon Bot</div><h2>{mode === 'setup' ? 'Create your owner account' : 'Welcome back'}</h2><form onSubmit={event => { event.preventDefault(); try { const url = productUrl(backendInput); setBaseUrl(url); setBackendError(undefined); } catch (error) { setBackendError(error); } }}><Field label="Product backend URL" hint="Connect to Lemon Bot, never the Lemon operator endpoint."><div className="row"><input type="url" required value={backendInput} onChange={event => setBackendInput(event.target.value)} /><button>Connect</button></div></Field></form><ErrorNotice error={backendError || setup.error}/>{setup.loading && !setup.data ? <Loading/> : setup.data && <><form className="stack" onSubmit={event => { event.preventDefault(); void action.run(async () => { const result = mode === 'setup' ? await client.call('POST /setup', { body: { clientNonce: nonce(), setupCode, email, password, displayName, workspaceName } }) : await client.call('POST /auth/login', { body: { clientNonce: nonce(), email, password } }); finish(result); }); }}>
      {mode === 'setup' && <><Field label="One-time owner setup code" hint="Your administrator gets this one-time code from the server’s terminal."><input required value={setupCode} autoComplete="off" onChange={event => setSetupCode(event.target.value)}/></Field><Field label="Workspace name"><input required maxLength={120} value={workspaceName} onChange={event => setWorkspaceName(event.target.value)}/></Field></>}
      {mode !== 'login' && <Field label="Your name"><input required maxLength={120} value={displayName} autoComplete="name" onChange={event => setDisplayName(event.target.value)}/></Field>}
      <Field label="Email"><input required type="email" value={email} autoComplete="username" onChange={event => setEmail(event.target.value)}/></Field><Field label="Password" hint={mode !== 'login' ? 'At least 12 characters.' : undefined}><input type="password" required minLength={mode === 'login' ? undefined : 12} value={password} autoComplete={mode === 'login' ? 'current-password' : 'new-password'} onChange={event => setPassword(event.target.value)}/></Field><ErrorNotice error={action.error}/><button className="primary" disabled={action.busy || pendingOIDC}>{action.busy ? 'Connecting…' : mode === 'setup' ? 'Create owner account' : 'Sign in'}</button></form>
      {mode === 'login' && <><ErrorNotice error={providers.error}/>{providers.data?.filter(provider => provider.enabled).map(provider => <button key={provider.id} disabled={action.busy} onClick={() => void action.run(async () => {
        const verifier = nonce() + nonce(); const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier)); const challenge = btoa(String.fromCharCode(...new Uint8Array(digest))).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
        const flow = await client.call('POST /auth/oidc/start', { body: { clientNonce: nonce(), providerId: provider.id, redirectUri: `${location.origin}/`, codeChallenge: challenge, purpose: 'login' } });
        const authorizationUrl = safeExternal(flow.authorizationUrl); if (!authorizationUrl) throw new Error('Provider returned an unsafe authorization URL.');
        sessionStorage.setItem('lemonbot.oidc.login', JSON.stringify({ baseUrl, flowId: flow.id, verifier })); location.assign(authorizationUrl);
      })}>Continue with {provider.name}{provider.requireSSO ? ' · SSO required' : ''}</button>)}</>}
      </>}
      {savedAccounts().length > 0 && <details><summary>Saved backend accounts</summary><div className="stack">{savedAccounts().map(account => <button key={`${account.baseUrl}:${account.email}`} onClick={() => { setBaseUrl(account.baseUrl); setBackendInput(account.baseUrl); setEmail(account.email); setMode('login'); }}>{account.workspaceName || account.baseUrl}<br/><small>{account.email}</small></button>)}</div></details>}
      <CleanupHandoffCard/>
      <p className="small muted">Your sign-in stays in this browser tab. Connected services need to be set up on your server. Your browser never gets administrator access to your computers.</p>
    </div></section></main>;
}
