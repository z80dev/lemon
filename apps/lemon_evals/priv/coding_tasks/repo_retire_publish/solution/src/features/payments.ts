import type { Context, DispatchTarget, DispatchReceipt } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { paymentId: string; cents: number };
export function capturePayment(bus: DispatchTarget, context: Context, input: Input): DispatchReceipt {
  const payload = { paymentId: text(input.paymentId, 'paymentId'), cents: positive(input.cents, 'cents') };
  return bus.dispatch({ tenantId: context.tenantId, actorId: context.actorId, key: context.requestId, topic: 'payment.captured', payload });
}
