import { useEffect, useRef, useState } from 'react';
import { LemonBotClient, type AuthResult } from '@lemon-bot/sdk';
import { rememberSession, type WebSession } from './auth';
import { useApp } from './app';
import { Loading, useQuery } from './ui';

export function takeSignInTicket(): string | null {
  if (typeof location === 'undefined' || !location.hash.startsWith('#lemonbot-signin=')) return null;
  const ticket = location.hash.slice('#lemonbot-signin='.length);
  history.replaceState(null, '', location.pathname + location.search);
  return /^[A-Za-z0-9_-]{43}$/.test(ticket) ? ticket : 'invalid';
}

export function ticketErrorNotice(error: unknown): string {
  const code = typeof error === 'string' ? error : error && typeof error === 'object' && 'code' in error ? error.code : undefined;
  switch (code) {
    case 'expired': return 'This sign-in link expired. Run `lemon-bot open` on this computer for a new one.';
    case 'invalid':
    case 'unauthenticated': return "This sign-in link was already used or isn't valid. Run `lemon-bot open` on this computer for a new one.";
    case 'forbidden': return 'Open the sign-in link on the computer running Lemon Bot, or through its SSH tunnel.';
    case 'capability_unavailable': return "This Lemon Bot doesn't accept sign-in links. Sign in with your email and password.";
    case 'rate_limited': return 'Too many failed sign-in links. Wait a minute, then run `lemon-bot open` again.';
    default: return 'Couldn’t finish signing in. Run `lemon-bot open` on this computer for a new link.';
  }
}

export function TicketSignIn({ ticket, onAuth, onFail }: { ticket: string; onAuth: (session: WebSession) => void; onFail: (error: unknown) => void }) {
  // Reuse the same promise across Strict Mode's effect replay: tickets are one-use.
  const redemption = useRef<Promise<AuthResult> | null>(null);
  useEffect(() => {
    let disposed = false;
    const baseUrl = `${location.origin}/v1`;
    redemption.current ??= ticket === 'invalid' ? Promise.reject('invalid') : new LemonBotClient({ baseUrl }).call('POST /auth/local/redeem', { body: { ticket } });
    void redemption.current.then(result => {
      if (disposed) return;
      const session = rememberSession(result, baseUrl);
      sessionStorage.setItem('lemonbot.localSignIn', '1');
      sessionStorage.removeItem('lemonbot.pending-link');
      history.replaceState(null, '', `${location.pathname}${location.search}#screen=home`);
      onAuth(session);
    }).catch(error => { if (!disposed) onFail(error); });
    return () => { disposed = true; };
  }, [ticket]);
  return <main className="boot stack"><Loading label="Signing you in…"/></main>;
}

export function useLocalConfirmation(until: number | null | undefined): boolean {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    setNow(Date.now());
    if (!until || until <= Date.now()) return;
    const timer = setTimeout(() => setNow(Date.now()), until - Date.now());
    return () => clearTimeout(timer);
  }, [until]);
  return !!until && until > Math.max(now, Date.now());
}

export function unlockNoticeKey(workspaceId: string, userId: string) { return `lemonbot.unlockNotice.dismissed:${workspaceId}:${userId}`; }

export function UnlockedNotice() {
  const { client, snapshot, navigate } = useApp();
  const methods = useQuery('sign-in:unlock-notice', () => client.call('GET /me/sign-in'));
  const fresh = useLocalConfirmation(methods.data?.localConfirmedUntilMs);
  const key = unlockNoticeKey(snapshot.workspace.id, snapshot.user.id);
  const [dismissed, setDismissed] = useState(() => !!localStorage.getItem(key));
  const owner = methods.data?.localOwner;
  if (dismissed || localStorage.getItem(key) || !sessionStorage.getItem('lemonbot.localSignIn') || methods.data?.password !== false || !owner || !fresh) return null;
  const mac = owner.platform === 'macos';
  const dismiss = () => { localStorage.setItem(key, '1'); setDismissed(true); };
  return <section className="panel stack" aria-labelledby="unlocked-notice-title"><h2 id="unlocked-notice-title">{mac ? 'Unlocked by your Mac login' : `Unlocked by your login on ${owner.hostName}`}</h2><p>You're signed in as the owner because you're logged in to {mac ? 'this Mac' : owner.hostName} as {owner.osUser} — no password needed here. Want to sign in from another computer's browser too? Add an email and password.</p><div className="row"><button className="primary" onClick={() => { dismiss(); navigate({ screen: 'settings.account' }); }}>Add email and password</button><button onClick={dismiss}>Not now</button></div></section>;
}
