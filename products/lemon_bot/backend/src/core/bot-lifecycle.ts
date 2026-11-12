import type * as P from '../../../contracts/protocol';
import type { BackendServices } from './services';

export const nativeFollowupAdmissionPath = '/internal/runtime/followup/admission';
interface LifecycleFence { action: string; status: P.BotLifecycle['status']; step?: string; message?: string }
interface SetupPlan { steps: Record<string, 'pending' | 'rejected' | 'acknowledged'> }

export function nativeAdmissionAddressChange(s: BackendServices, bot: P.Bot): string | null {
  const old = s.store.metadata<{ url: string }>(`nativeFollowupIssuerConfig:${bot.id}`);
  const url = new URL(nativeFollowupAdmissionPath, s.config.publicUrl).toString();
  return old && old.url !== url ? `Lemon Bot's address changed from ${new URL(old.url).origin} to ${new URL(url).origin}. Choose Update address to configure the new callback; add ${new URL(url).origin} to LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS on the controller first (see the Lemon Bot getting-started guide).` : null;
}

/** Read-only projection: a persisted running fence stays running until its owner reconciles it. */
export function botLifecycleProjection(s: BackendServices, bot: P.Bot): P.BotLifecycle | undefined {
  const fence = s.store.metadata<LifecycleFence>(`botLifecycle:${bot.id}`);
  const addressChange = nativeAdmissionAddressChange(s, bot);
  const addressRecovery = s.store.metadata<string>(`botReaddressTarget:${bot.id}`) !== null && ['Update callback address', 'Update Bot address', 'Sync updated address'].some(step => s.store.metadata<SetupPlan>(`botSetup:${bot.id}`)?.steps[step] !== 'acknowledged');
  return fence ? {
    action: fence.action, status: fence.status, step: fence.step ?? 'Finish Bot setup',
    message: addressChange ?? (addressRecovery ? `${s.store.metadata<string>(`botReaddressNotice:${bot.id}`) ?? 'Continue updating the Bot address.'} ${fence.message ?? ''}` : fence.message) ?? 'Setup was interrupted. Choose Finish setup to check its receipts, or Delete to remove this Bot.',
    canFinishSetup: ['create', 'import'].includes(fence.action) && fence.status !== 'running',
    canReaddress: (!!addressChange || addressRecovery || fence.action === 'readdress') && fence.status !== 'running' && ['create', 'import', 'update', 'readdress'].includes(fence.action),
    canDelete: fence.status !== 'running' && (['create', 'import', 'readdress'].includes(fence.action) || fence.action === 'delete' && fence.status === 'failed'),
  } : addressChange ? { action: 'readdress', status: 'failed', step: 'Update callback address', message: addressChange, canFinishSetup: false, canReaddress: true, canDelete: true } : undefined;
}
