import type { Route } from '../../types.ts';
export const route: Route = Object.freeze({ name: 'health', method: 'GET', path: '/v1/health', requiresActor: false,
  handle: () => ({ status: 200, body: { ok: true } }) });
