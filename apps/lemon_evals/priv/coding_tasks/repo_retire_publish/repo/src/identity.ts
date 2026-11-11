import type { DispatchRequest } from './types.ts';
export function identity(request: DispatchRequest): string { return JSON.stringify([request.tenantId, request.topic, request.key]); }
