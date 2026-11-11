import type { Context } from './types.ts';
export function context(tenantId: string, actorId: string, requestId: string): Context { return { tenantId, actorId, requestId }; }
