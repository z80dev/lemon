import { LemonBotError, type RealtimeState } from '@lemon-bot/sdk';

const labels: Record<RealtimeState, string> = {
  connecting: 'Connecting', authenticating: 'Signing in', syncing: 'Updating', replaying: 'Catching up', live: 'Connected',
  reconnecting: 'Reconnecting', unauthenticated: 'Session ended', forbidden: 'Session ended', error: 'Connection failed', closed: 'Disconnected',
};
export function connectionLabel(state: RealtimeState, browserOnline: boolean, controlConnected?: boolean): string {
  if (!browserOnline) return 'Offline';
  if (state === 'live' && controlConnected === false) return 'Lemon disconnected';
  return labels[state];
}
export function sessionEnded(error: unknown): boolean {
  return error instanceof LemonBotError && (error.status === 401 || error.status === 403 || error.code === 'unauthenticated' || error.code === 'forbidden');
}
export function connectionIssue(state: RealtimeState, browserOnline: boolean, controlConnected: boolean | undefined, error: unknown) {
  if (state === 'unauthenticated' || state === 'forbidden' || sessionEnded(error)) return { layer: 'session', title: 'Your session ended. Sign in again.', reason: 'This browser is no longer signed in to Lemon Bot.' };
  if (!browserOnline) return { layer: 'offline', title: 'Your browser is offline', reason: 'Reconnect to your network or Tailscale, then try again. Drafts stay in this browser. Approvals and deletions wait until you reconnect.' };
  if (state === 'live' && controlConnected === false) return { layer: 'controller', title: 'Lemon isn’t connected', reason: 'Lemon Bot is reachable, but its link to Lemon is down. Bots can’t work until Lemon reconnects.' };
  const status = error instanceof LemonBotError ? error.status : 0;
  if (status >= 500) return { layer: 'server', title: 'Lemon Bot is having a server problem', reason: status === 502 || status === 504 ? 'The proxy is answering, but it can’t reach the Lemon Bot service behind it.' : `The Lemon Bot service couldn’t complete the request (${status}). Try again shortly.` };
  if (error) return { layer: 'backend', title: 'Can’t reach Lemon Bot', reason: 'The connection failed. Check that the Lemon Bot service is running and that your network or Tailscale connection is available.' };
  return { layer: 'connecting', title: state === 'reconnecting' ? 'Reconnecting to Lemon Bot' : 'Connecting to Lemon Bot', reason: 'Waiting for a connection and up-to-date workspace details. Anything shown may be out of date.' };
}
