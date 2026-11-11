import type { Context, LegacyPublisher } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { projectId: string; slug: string };
export function createProject(bus: LegacyPublisher, context: Context, input: Input): string {
  const payload = { projectId: text(input.projectId, 'projectId'), slug: text(input.slug, 'slug').toLowerCase().replace(/\s+/g, '-') };
  return bus.publish('project.created', payload);
}
