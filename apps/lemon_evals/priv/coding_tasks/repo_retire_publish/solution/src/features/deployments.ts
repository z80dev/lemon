import type { Context, DispatchTarget, DispatchReceipt } from '../types.ts';
import { text, positive, email } from '../feature-input.ts';
export type Input = { deploymentId: string; environment: string };
export function promoteDeployment(bus: DispatchTarget, context: Context, input: Input): DispatchReceipt {
  const payload = { deploymentId: text(input.deploymentId, 'deploymentId'), environment: text(input.environment, 'environment').toLowerCase() };
  return bus.dispatch({ tenantId: context.tenantId, actorId: context.actorId, key: context.requestId, topic: 'deployment.promoted', payload });
}
