import type { Route } from '../../types.ts';
import { report } from '../../services/report-service.ts';
export const route: Route = Object.freeze({ name: 'report', method: 'GET', path: '/v1/report', requiresActor: false,
  handle: (_request, _context, services) => ({ status: 200, body: report(services) }) });
