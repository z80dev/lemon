import type { Context, DispatchTarget, DispatchReceipt } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { threadId: string; body: string };
export function addComment(bus: DispatchTarget, context: Context, input: Input): DispatchReceipt {
  const payload = { threadId: text(input.threadId, 'threadId'), body: text(input.body, 'body') };
  return bus.dispatch({ tenantId: context.tenantId, actorId: context.actorId, key: context.requestId, topic: 'comment.added', payload });
}
