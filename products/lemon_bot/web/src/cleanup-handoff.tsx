import { useEffect, useState } from 'react';
import type { ErrorCode } from '@lemon-bot/sdk';
import { ErrorNotice, formatTime } from './ui';

export interface CleanupHandoff {
  backendUrl: string; workspaceId: string; userId: string; clientNonce: string; requestedAtMs: number;
  status: 'prepared' | 'product_delete_acknowledged' | 'outcome_unknown' | 'refused';
  teardownId?: string; requestId?: string; errorCode?: ErrorCode;
}
const storageKey = 'lemonbot.cleanup-handoff';
export function readCleanupHandoff(): CleanupHandoff | undefined {
  try {
    const value: unknown = JSON.parse(localStorage.getItem(storageKey) || 'null');
    if (!value || typeof value !== 'object' || !('backendUrl' in value) || typeof value.backendUrl !== 'string' || !('workspaceId' in value) || typeof value.workspaceId !== 'string' || !('userId' in value) || typeof value.userId !== 'string' || !('clientNonce' in value) || typeof value.clientNonce !== 'string' || !('requestedAtMs' in value) || typeof value.requestedAtMs !== 'number' || !Number.isFinite(value.requestedAtMs) || !('status' in value)) return;
    if (value.status !== 'prepared' && value.status !== 'product_delete_acknowledged' && value.status !== 'outcome_unknown' && value.status !== 'refused') return;
    const result: CleanupHandoff = { backendUrl: value.backendUrl, workspaceId: value.workspaceId, userId: value.userId, clientNonce: value.clientNonce, requestedAtMs: value.requestedAtMs, status: value.status };
    if ('teardownId' in value && typeof value.teardownId === 'string') result.teardownId = value.teardownId;
    if ('requestId' in value && typeof value.requestId === 'string') result.requestId = value.requestId;
    if ('errorCode' in value && typeof value.errorCode === 'string' && value.errorCode.length <= 80) result.errorCode = value.errorCode as ErrorCode;
    return result;
  } catch { return; }
}
export function persistCleanupHandoff(value: CleanupHandoff) {
  localStorage.setItem(storageKey, JSON.stringify(value));
  window.dispatchEvent(new Event('lemonbot:cleanup-handoff'));
}
export function CleanupHandoffCard() {
  const [handoff, setHandoff] = useState(readCleanupHandoff);
  const [error, setError] = useState<unknown>();
  useEffect(() => { const change = () => setHandoff(readCleanupHandoff()); window.addEventListener('lemonbot:cleanup-handoff', change); return () => window.removeEventListener('lemonbot:cleanup-handoff', change); }, []);
  if (!handoff) return null;
  return <section className="panel stack" aria-label="Account cleanup diagnostics"><h3>Account cleanup handoff</h3>
    <p className="small muted">These are safe diagnostic IDs, not credentials or a read capability. The deleted account cannot sign back in to inspect cleanup. Ask an enabled workspace Owner to use the authenticated Account cleanup screen.</p>
    <p>{handoff.status === 'product_delete_acknowledged' ? 'Product account removal was acknowledged; this does not prove external provider cleanup completed.' : handoff.status === 'refused' ? 'The request was refused. No completed cleanup is inferred.' : 'The deletion request outcome is not confirmed. Do not submit another Delete.'}</p>
    <dl className="small"><dt>Backend</dt><dd>{handoff.backendUrl}</dd><dt>Workspace</dt><dd>{handoff.workspaceId}</dd><dt>User</dt><dd>{handoff.userId}</dd>{handoff.teardownId && <><dt>Operation</dt><dd>{handoff.teardownId}</dd></>}{handoff.requestId && <><dt>Request</dt><dd>{handoff.requestId}</dd></>}<dt>Requested</dt><dd>{formatTime(handoff.requestedAtMs)}</dd>{handoff.errorCode && <><dt>Outcome code</dt><dd>{handoff.errorCode}</dd></>}</dl>
    <ErrorNotice error={error}/><div className="row"><button onClick={() => void navigator.clipboard.writeText(JSON.stringify(handoff, null, 2)).catch(setError)}>Copy safe diagnostics for Owner</button><button onClick={() => { localStorage.removeItem(storageKey); setHandoff(undefined); }}>Clear local diagnostic handoff</button></div>
  </section>;
}
