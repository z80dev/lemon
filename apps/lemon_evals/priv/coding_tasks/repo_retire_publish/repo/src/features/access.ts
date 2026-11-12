import type { Context, LegacyPublisher } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { memberId: string; reason: string };
export function revokeAccess(bus: LegacyPublisher, context: Context, input: Input): string {
  const payload = { memberId: text(input.memberId, 'memberId'), reason: text(input.reason, 'reason') };
  return bus.publish('access.revoked', payload);
}
