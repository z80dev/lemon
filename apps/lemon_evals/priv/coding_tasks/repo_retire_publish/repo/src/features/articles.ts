import type { Context, LegacyPublisher } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { articleId: string; title: string };
export function releaseArticle(bus: LegacyPublisher, context: Context, input: Input): string {
  const payload = { articleId: text(input.articleId, 'articleId'), title: text(input.title, 'title') };
  return bus.publish('article.released', payload);
}
