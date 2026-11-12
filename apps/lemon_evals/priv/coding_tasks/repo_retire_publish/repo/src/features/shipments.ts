import type { Context, LegacyPublisher } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { shipmentId: string; tracking: string };
export function packShipment(bus: LegacyPublisher, context: Context, input: Input): string {
  const payload = { shipmentId: text(input.shipmentId, 'shipmentId'), tracking: text(input.tracking, 'tracking').toUpperCase() };
  return bus.publish('shipment.packed', payload);
}
