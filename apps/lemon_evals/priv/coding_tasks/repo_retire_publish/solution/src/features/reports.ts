import type { Context, DispatchTarget, DispatchReceipt } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { reportId: string; format: string };
export function scheduleReport(bus: DispatchTarget, context: Context, input: Input): DispatchReceipt {
  const payload = { reportId: text(input.reportId, 'reportId'), format: text(input.format, 'format').toLowerCase() };
  return bus.dispatch({ tenantId: context.tenantId, actorId: context.actorId, key: context.requestId, topic: 'report.scheduled', payload });
}
