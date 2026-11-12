import type { Context, DispatchTarget, DispatchReceipt } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { incidentId: string; severity: number };
export function openIncident(bus: DispatchTarget, context: Context, input: Input): DispatchReceipt {
  const payload = { incidentId: text(input.incidentId, 'incidentId'), severity: positive(input.severity, 'severity') };
  return bus.dispatch({ tenantId: context.tenantId, actorId: context.actorId, key: context.requestId, topic: 'incident.opened', payload });
}
