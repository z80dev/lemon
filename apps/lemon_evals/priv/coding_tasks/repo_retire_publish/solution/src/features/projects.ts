import type { Context, DispatchTarget, DispatchReceipt } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { projectId: string; slug: string };
export function createProject(bus: DispatchTarget, context: Context, input: Input): DispatchReceipt {
  const payload = { projectId: text(input.projectId, 'projectId'), slug: text(input.slug, 'slug').toLowerCase().replace(/\s+/g, '-') };
  return bus.dispatch({ tenantId: context.tenantId, actorId: context.actorId, key: context.requestId, topic: 'project.created', payload });
}
