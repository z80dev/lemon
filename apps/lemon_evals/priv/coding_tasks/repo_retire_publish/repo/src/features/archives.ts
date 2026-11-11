import type { Context, LegacyPublisher } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { documentId: string; reason: string };
export function archiveDocument(bus: LegacyPublisher, context: Context, input: Input): string {
  const payload = { documentId: text(input.documentId, 'documentId'), reason: text(input.reason, 'reason') };
  return bus.publish('document.archived', payload);
}
