import type { Context, DispatchTarget, DispatchReceipt } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { email: string; role: string };
export function inviteMember(bus: DispatchTarget, context: Context, input: Input): DispatchReceipt {
  const payload = { email: email(input.email), role: text(input.role, 'role').toLowerCase() };
  return bus.dispatch({ tenantId: context.tenantId, actorId: context.actorId, key: context.requestId, topic: 'member.invited', payload });
}
