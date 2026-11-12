import type { Context, LegacyPublisher } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { email: string; role: string };
export function inviteMember(bus: LegacyPublisher, context: Context, input: Input): string {
  const payload = { email: email(input.email), role: text(input.role, 'role').toLowerCase() };
  return bus.publish('member.invited', payload);
}
