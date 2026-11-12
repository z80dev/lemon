import type { Context, DispatchTarget, DispatchReceipt } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { articleId: string; title: string };
export function releaseArticle(bus: DispatchTarget, context: Context, input: Input): DispatchReceipt {
  const payload = { articleId: text(input.articleId, 'articleId'), title: text(input.title, 'title') };
  return bus.dispatch({ tenantId: context.tenantId, actorId: context.actorId, key: context.requestId, topic: 'article.released', payload });
}
