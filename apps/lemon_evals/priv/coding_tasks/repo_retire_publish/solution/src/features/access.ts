import type { Context, DispatchTarget, DispatchReceipt } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { memberId: string; reason: string };
export function revokeAccess(bus: DispatchTarget, context: Context, input: Input): DispatchReceipt {
  const payload = { memberId: text(input.memberId, 'memberId'), reason: text(input.reason, 'reason') };
  return bus.dispatch({ tenantId: context.tenantId, actorId: context.actorId, key: context.requestId, topic: 'access.revoked', payload });
}
