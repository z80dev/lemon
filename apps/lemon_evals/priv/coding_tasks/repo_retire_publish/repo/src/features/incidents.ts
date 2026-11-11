import type { Context, LegacyPublisher } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { incidentId: string; severity: number };
export function openIncident(bus: LegacyPublisher, context: Context, input: Input): string {
  const payload = { incidentId: text(input.incidentId, 'incidentId'), severity: positive(input.severity, 'severity') };
  return bus.publish('incident.opened', payload);
}
