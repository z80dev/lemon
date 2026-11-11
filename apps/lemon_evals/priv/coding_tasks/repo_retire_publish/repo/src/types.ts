export type Context = { tenantId: string; actorId: string; requestId: string };
export type DispatchRequest = { tenantId: string; actorId: string; key: string; topic: string; payload: Record<string, unknown> };
export type DispatchReceipt = { id: string; accepted: boolean };
export type Event = DispatchRequest & { id: string };
export type DispatchTarget = { dispatch(request: DispatchRequest): DispatchReceipt };
export type LegacyPublisher = { publish(topic: string, payload: Record<string, unknown>): string };
