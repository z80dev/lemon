import type { Route } from '../../types.ts';
import { listStock } from '../../services/catalog-service.ts';
export const route: Route = Object.freeze({ name: 'stock-list', method: 'GET', path: '/v1/health', requiresActor: false,
  handle: (_request, _context, services) => ({ status: 200, body: { items: listStock(services) } }) });
