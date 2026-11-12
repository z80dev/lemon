import { Catalog } from './domain/catalog.ts';
import { StockLedger } from './domain/stock.ts';
import { ReservationBook } from './domain/reservations.ts';
import { AuditLog } from './domain/audit.ts';
import { routes } from './http/manifest.ts';
import { routeRequest } from './http/router.ts';
import type { Context, Request, Services } from './types.ts';
export function createApp() {
  const services: Services = { catalog: new Catalog(), stock: new StockLedger(), reservations: new ReservationBook(), audit: new AuditLog() };
  return { services, handle(request: Request, context: Context) { return routeRequest(routes, services, request, context); } };
}
