import type { DispatchRequest } from './types.ts';
export function validateRequest(request: DispatchRequest): void {
  for (const field of ['tenantId', 'actorId', 'key', 'topic'] as const) {
    if (typeof request[field] !== 'string' || !request[field].trim()) throw new Error(`${field} must be nonempty`);
  }
  if (!/^[a-z]+(?:\.[a-z]+)+$/.test(request.topic)) throw new Error('topic must be dotted lowercase words');
  if (request.payload === null || typeof request.payload !== 'object' || Array.isArray(request.payload)) throw new Error('payload must be an object');
}
