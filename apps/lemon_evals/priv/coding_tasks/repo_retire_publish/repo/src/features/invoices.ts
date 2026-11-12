import type { Context, LegacyPublisher } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { invoiceId: string; cents: number };
export function issueInvoice(bus: LegacyPublisher, context: Context, input: Input): string {
  const payload = { invoiceId: text(input.invoiceId, 'invoiceId'), cents: positive(input.cents, 'cents'), currency: 'USD' };
  return bus.publish('invoice.issued', payload);
}
