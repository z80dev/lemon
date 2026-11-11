import type { Route } from '../../types.ts';
import { cancel } from '../../services/reservation-service.ts';
import { reservationId } from '../../validation.ts';
export const route: Route = Object.freeze({ name: 'reservation-cancel', method: 'POST', path: '/v1/reservations/:reservationId/cancel', requiresActor: true,
  handle: (_request, context, services, params) => ({ status: 200, body: cancel(services, context, reservationId(params.reservationId)) }) });
