import type { Context, DispatchTarget, DispatchReceipt } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { orderId: string; lines: number };
export function submitOrder(bus: DispatchTarget, context: Context, input: Input): DispatchReceipt {
  const payload = { orderId: text(input.orderId, 'orderId'), lines: positive(input.lines, 'lines') };
  return bus.dispatch({ tenantId: context.tenantId, actorId: context.actorId, key: context.requestId, topic: 'order.submitted', payload });
}
