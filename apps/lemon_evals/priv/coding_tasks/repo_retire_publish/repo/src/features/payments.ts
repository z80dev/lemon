import type { Context, LegacyPublisher } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { paymentId: string; cents: number };
export function capturePayment(bus: LegacyPublisher, context: Context, input: Input): string {
  const payload = { paymentId: text(input.paymentId, 'paymentId'), cents: positive(input.cents, 'cents') };
  return bus.publish('payment.captured', payload);
}
