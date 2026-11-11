import type { Context, DispatchTarget, DispatchReceipt } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { documentId: string; reason: string };
export function archiveDocument(bus: DispatchTarget, context: Context, input: Input): DispatchReceipt {
  const payload = { documentId: text(input.documentId, 'documentId'), reason: text(input.reason, 'reason') };
  return bus.dispatch({ tenantId: context.tenantId, actorId: context.actorId, key: context.requestId, topic: 'document.archived', payload });
}
