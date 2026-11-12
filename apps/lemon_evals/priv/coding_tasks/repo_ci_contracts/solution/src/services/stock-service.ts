import type { Services, Context } from '../types.ts';
import { sku, quantity } from '../validation.ts';
export function addStock(services: Services, context: Context, input: Record<string, unknown>) {
  const code = sku(input.sku); const count = quantity(input.quantity);
  services.catalog.add(code);
  const result = services.stock.add(code, count);
  services.audit.record({ action: 'stock.added', actorId: context.actorId!, at: context.clock(), subject: code });
  return result;
}
