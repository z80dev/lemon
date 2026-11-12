import type { Context, LegacyPublisher } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { orderId: string; lines: number };
export function submitOrder(bus: LegacyPublisher, context: Context, input: Input): string {
  const payload = { orderId: text(input.orderId, 'orderId'), lines: positive(input.lines, 'lines') };
  return bus.publish('order.submitted', payload);
}
