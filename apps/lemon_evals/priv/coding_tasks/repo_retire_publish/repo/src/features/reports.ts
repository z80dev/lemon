import type { Context, LegacyPublisher } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { reportId: string; format: string };
export function scheduleReport(bus: LegacyPublisher, context: Context, input: Input): string {
  const payload = { reportId: text(input.reportId, 'reportId'), format: text(input.format, 'format').toLowerCase() };
  return bus.publish('report.scheduled', payload);
}
