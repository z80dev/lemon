import type { Context, DispatchTarget, DispatchReceipt } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { shipmentId: string; tracking: string };
export function packShipment(bus: DispatchTarget, context: Context, input: Input): DispatchReceipt {
  const payload = { shipmentId: text(input.shipmentId, 'shipmentId'), tracking: text(input.tracking, 'tracking').toUpperCase() };
  return bus.dispatch({ tenantId: context.tenantId, actorId: context.actorId, key: context.requestId, topic: 'shipment.packed', payload });
}
