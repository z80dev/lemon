import type { Route } from '../../types.ts';
import { fulfill } from '../../services/reservation-service.ts';
import { reservationId } from '../../validation.ts';
export const route: Route = Object.freeze({ name: 'reservation-fulfill', method: 'POST', path: '/v1/reservations/:reservationId/fulfill', requiresActor: true,
  handle: (_request, context, services, params) => ({ status: 200, body: fulfill(services, context, reservationId(params.reservationId)) }) });
