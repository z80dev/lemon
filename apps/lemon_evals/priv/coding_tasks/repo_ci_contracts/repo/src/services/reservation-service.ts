import type { Services, Context } from '../types.ts';
import { sku, quantity, reservationId } from '../validation.ts';
import { conflict } from '../errors.ts';
export function reserve(services: Services, context: Context, input: Record<string, unknown>) {
  const code = sku(input.sku); const count = quantity(input.quantity); const id = reservationId(input.reservationId);
  services.reservations.ensureUnused(id); services.stock.reserve(code, count);
  const row = services.reservations.create(id, code, count);
  services.audit.record({ action: 'reservation.created', actorId: context.actorId!, at: context.clock(), subject: id });
  return row;
}
export function cancel(services: Services, context: Context, id: string) {
  const row = services.reservations.get(id);
  if (row.status === 'fulfilled') return conflict('reservation already fulfilled');
  services.stock.release(row.sku, row.quantity);
  const result = services.reservations.setStatus(id, 'cancelled');
  services.audit.record({ action: 'reservation.cancelled', actorId: context.actorId!, at: context.clock(), subject: id });
  return result;
}
export function fulfill(services: Services, context: Context, id: string) {
  const row = services.reservations.get(id);
  if (row.status !== 'active') return conflict('reservation is not active');
  services.stock.fulfill(row.sku, row.quantity);
  const result = services.reservations.setStatus(id, 'fulfilled');
  services.audit.record({ action: 'reservation.fulfilled', actorId: context.actorId!, at: context.clock(), subject: id });
  return result;
}
