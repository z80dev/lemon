import { LemonBotError, type LemonBotClient, type ProviderDefaultSet, type ProviderDeviceLogin, type ProviderManagement, type ProviderTargetRequest } from '@lemon-bot/sdk';

export const codexVerificationUrl = 'https://auth.openai.com/codex/device';
export type DeviceAction = 'start' | 'poll' | 'cancel';
export type ProviderIntent =
  | { kind: 'api_key' | 'disconnect'; clientNonce: string; targetId: string; providerId: string }
  | { kind: 'default'; clientNonce: string; targetId: string; providerId: string; modelId: string }
  | { kind: 'device'; clientNonce: string; targetId: string; providerId: 'openai_codex'; pollNonce: string; cancelNonce: string; action: DeviceAction; startedAtMs: number };

/** The journal is an allowlist of safe reconciliation metadata, never request bodies or receipts. */
export function readProviderIntent(storageKey: string): ProviderIntent | null {
  try {
    const value = JSON.parse(sessionStorage.getItem(storageKey) || 'null');
    const bounded = (item: unknown): item is string => typeof item === 'string' && item.length > 0 && item.length <= 256 && !/[\u0000-\u001f]/.test(item);
    if (!value || !bounded(value.clientNonce) || !bounded(value.targetId) || !bounded(value.providerId)) return null;
    const common = { clientNonce: value.clientNonce, targetId: value.targetId, providerId: value.providerId };
    if (value.kind === 'api_key' || value.kind === 'disconnect') return { ...common, kind: value.kind };
    if (value.kind === 'default' && bounded(value.modelId)) return { ...common, kind: 'default', modelId: value.modelId };
    if (value.kind === 'device' && value.providerId === 'openai_codex' && bounded(value.pollNonce) && bounded(value.cancelNonce) && ['start', 'poll', 'cancel'].includes(value.action) && typeof value.startedAtMs === 'number' && Number.isFinite(value.startedAtMs) && value.startedAtMs > 0) {
      return { ...common, kind: 'device', providerId: 'openai_codex', pollNonce: value.pollNonce, cancelNonce: value.cancelNonce, action: value.action, startedAtMs: value.startedAtMs };
    }
  } catch { /* Storage may be unavailable. No secret recovery path exists. */ }
  return null;
}

/** Never retain a credential failure's arbitrary message, details, cause or resource payload. */
export function providerFailure(failure: unknown): { unknown: boolean; message: string } {
  if (!(failure instanceof LemonBotError) || failure.outcomeUnknown || !failure.retrySafe) return { unknown: true, message: 'We couldn’t confirm this change. Nothing will be sent again automatically. Check status before continuing.' };
  if (failure.code === 'unauthenticated' || failure.code === 'forbidden') return { unknown: false, message: 'Your owner access is no longer authorized. Sign in again and check the execution target.' };
  if (failure.code === 'machine_offline') return { unknown: false, message: 'The execution target is offline. Reconnect it, then check status.' };
  if (failure.code === 'capability_unavailable') return { unknown: false, message: 'This sign-in method is not available on the execution target.' };
  return { unknown: false, message: 'The change could not be completed. Check status and the target’s provider configuration before trying again.' };
}

export interface ProviderApi {
  status: () => Promise<ProviderManagement>;
  key: (providerId: string, body: ProviderTargetRequest & { value: string }) => Promise<ProviderManagement>;
  disconnect: (providerId: string, body: ProviderTargetRequest) => Promise<ProviderManagement>;
  changeDefault: (body: ProviderDefaultSet) => Promise<ProviderManagement>;
  device: (intent: Extract<ProviderIntent, { kind: 'device' }>) => Promise<ProviderDeviceLogin>;
}

export function providerApi(client: LemonBotClient, machineId?: string): ProviderApi {
  return {
    status: () => machineId ? client.call('GET /machines/:id/providers', { params: { id: machineId } }) : client.call('GET /instance/providers'),
    key: (providerId: string, body: ProviderTargetRequest & { value: string }) => machineId
      ? client.call('PUT /machines/:id/providers/:providerId/api-key', { params: { id: machineId, providerId }, body })
      : client.call('PUT /instance/providers/:providerId/api-key', { params: { providerId }, body }),
    disconnect: (providerId: string, body: ProviderTargetRequest) => machineId
      ? client.call('POST /machines/:id/providers/:providerId/disconnect', { params: { id: machineId, providerId }, body })
      : client.call('POST /instance/providers/:providerId/disconnect', { params: { providerId }, body }),
    changeDefault: (body: ProviderDefaultSet) => machineId
      ? client.call('POST /machines/:id/providers/default', { params: { id: machineId }, body })
      : client.call('POST /instance/providers/default', { body }),
    device: (intent: Extract<ProviderIntent, { kind: 'device' }>): Promise<ProviderDeviceLogin> => {
      const { targetId, providerId, clientNonce: loginId, action } = intent;
      const body = { targetId, clientNonce: action === 'start' ? loginId : action === 'poll' ? intent.pollNonce : intent.cancelNonce };
      if (machineId) {
        const params = { id: machineId, providerId, loginId };
        if (action === 'start') return client.call('POST /machines/:id/providers/:providerId/device-login', { params: { id: machineId, providerId }, body });
        if (action === 'poll') return client.call('POST /machines/:id/providers/:providerId/device-login/:loginId/poll', { params, body });
        return client.call('POST /machines/:id/providers/:providerId/device-login/:loginId/cancel', { params, body });
      }
      const params = { providerId, loginId };
      if (action === 'start') return client.call('POST /instance/providers/:providerId/device-login', { params: { providerId }, body });
      if (action === 'poll') return client.call('POST /instance/providers/:providerId/device-login/:loginId/poll', { params, body });
      return client.call('POST /instance/providers/:providerId/device-login/:loginId/cancel', { params, body });
    },
  };
}

export function checkedDeviceLogin(result: ProviderDeviceLogin, intent: Extract<ProviderIntent, { kind: 'device' }>): ProviderDeviceLogin {
  if (result.loginId !== intent.clientNonce || result.targetId !== intent.targetId || result.providerId !== 'openai_codex'
    || !['starting', 'pending', 'completed', 'denied', 'expired', 'cancelled', 'lost', 'failed'].includes(result.status)) throw new Error('Invalid device-login receipt');
  if (result.status === 'pending') {
    if (result.verificationUrl !== codexVerificationUrl || typeof result.userCode !== 'string' || !/^[A-Za-z0-9-]{1,64}$/.test(result.userCode)
      || !Number.isSafeInteger(result.expiresAtMs) || !result.expiresAtMs || result.expiresAtMs < 0 || !Number.isSafeInteger(result.pollIntervalMs) || !result.pollIntervalMs || result.pollIntervalMs < 1000 || result.pollIntervalMs > 60000) throw new Error('Invalid device-login receipt');
  } else if (result.verificationUrl !== null || result.userCode !== null || result.expiresAtMs !== null || result.pollIntervalMs !== null) throw new Error('Invalid device-login receipt');
  // Copy only the public fields, even if an unexpected transport adds other properties.
  return { loginId: result.loginId, targetId: result.targetId, providerId: result.providerId, status: result.status, verificationUrl: result.verificationUrl, userCode: result.userCode, expiresAtMs: result.expiresAtMs, pollIntervalMs: result.pollIntervalMs };
}
