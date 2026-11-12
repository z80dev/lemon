import type { Context, LegacyPublisher } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { threadId: string; body: string };
export function addComment(bus: LegacyPublisher, context: Context, input: Input): string {
  const payload = { threadId: text(input.threadId, 'threadId'), body: text(input.body, 'body') };
  return bus.publish('comment.added', payload);
}
