import type { Context, DispatchTarget, DispatchReceipt } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { invoiceId: string; cents: number };
export function issueInvoice(bus: DispatchTarget, context: Context, input: Input): DispatchReceipt {
  const payload = { invoiceId: text(input.invoiceId, 'invoiceId'), cents: positive(input.cents, 'cents'), currency: 'USD' };
  return bus.dispatch({ tenantId: context.tenantId, actorId: context.actorId, key: context.requestId, topic: 'invoice.issued', payload });
}
