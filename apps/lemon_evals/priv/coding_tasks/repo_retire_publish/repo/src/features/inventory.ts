import type { Context, LegacyPublisher } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { sku: string; quantity: number };
export function reserveInventory(bus: LegacyPublisher, context: Context, input: Input): string {
  const payload = { sku: text(input.sku, 'sku').toUpperCase(), quantity: positive(input.quantity, 'quantity') };
  return bus.publish('inventory.reserved', payload);
}
