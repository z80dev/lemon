import type { Context, LegacyPublisher } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { paymentId: string; cents: number; reason: string };
export function requestRefund(bus: LegacyPublisher, context: Context, input: Input): string {
  const payload = { paymentId: text(input.paymentId, 'paymentId'), cents: positive(input.cents, 'cents'), reason: text(input.reason, 'reason') };
  return bus.publish('refund.requested', payload);
}
