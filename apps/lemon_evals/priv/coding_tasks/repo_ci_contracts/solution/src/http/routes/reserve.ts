import type { Route } from '../../types.ts';
import { reserve } from '../../services/reservation-service.ts';
export const route: Route = Object.freeze({ name: 'reservation-create', method: 'POST', path: '/v1/reservations', requiresActor: true,
  handle: (request, context, services) => ({ status: 201, body: reserve(services, context, request.body ?? {}) }) });
