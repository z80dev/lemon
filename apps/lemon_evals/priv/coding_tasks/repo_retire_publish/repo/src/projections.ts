import type { Event } from './types.ts';
export function topicCounts(events: Event[]): Record<string, number> {
  const counts: Record<string, number> = {};
  for (const event of events) counts[event.topic] = (counts[event.topic] ?? 0) + 1;
  return counts;
}
export function tenantEvents(events: Event[], tenantId: string): Event[] { return events.filter(event => event.tenantId === tenantId); }
