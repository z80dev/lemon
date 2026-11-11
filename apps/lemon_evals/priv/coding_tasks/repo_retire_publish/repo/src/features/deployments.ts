import type { Context, LegacyPublisher } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { deploymentId: string; environment: string };
export function promoteDeployment(bus: LegacyPublisher, context: Context, input: Input): string {
  const payload = { deploymentId: text(input.deploymentId, 'deploymentId'), environment: text(input.environment, 'environment').toLowerCase() };
  return bus.publish('deployment.promoted', payload);
}
