import type { Context, DispatchTarget, DispatchReceipt } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { paymentId: string; cents: number; reason: string };
export function requestRefund(bus: DispatchTarget, context: Context, input: Input): DispatchReceipt {
  const payload = { paymentId: text(input.paymentId, 'paymentId'), cents: positive(input.cents, 'cents'), reason: text(input.reason, 'reason') };
  return bus.dispatch({ tenantId: context.tenantId, actorId: context.actorId, key: context.requestId, topic: 'refund.requested', payload });
}
