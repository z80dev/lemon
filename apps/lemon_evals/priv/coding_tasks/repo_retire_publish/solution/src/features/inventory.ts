import type { Context, DispatchTarget, DispatchReceipt } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { sku: string; quantity: number };
export function reserveInventory(bus: DispatchTarget, context: Context, input: Input): DispatchReceipt {
  const payload = { sku: text(input.sku, 'sku').toUpperCase(), quantity: positive(input.quantity, 'quantity') };
  return bus.dispatch({ tenantId: context.tenantId, actorId: context.actorId, key: context.requestId, topic: 'inventory.reserved', payload });
}
