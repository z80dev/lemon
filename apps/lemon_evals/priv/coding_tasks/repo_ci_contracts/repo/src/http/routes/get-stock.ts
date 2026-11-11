import type { Route } from '../../types.ts';
import { sku } from '../../validation.ts';
export const route: Route = Object.freeze({ name: 'stock-get', method: 'GET', path: '/v1/stock/:sku', requiresActor: false,
  handle: (_request, _context, services, params) => ({ status: 200, body: services.stock.get(sku(params.sku)) }) });
