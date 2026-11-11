import type { Route } from '../../types.ts';
import { addStock } from '../../services/stock-service.ts';
export const route: Route = Object.freeze({ name: 'Stock_Add', method: 'POST', path: '/v1/stock', requiresActor: true,
  handle: (request, context, services) => ({ status: 200, body: addStock(services, context, request.body ?? {}) }) });
