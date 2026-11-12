import type { Services } from '../types.ts';
import { listStock } from './catalog-service.ts';
import { summarize } from '../domain/summary.ts';
export function report(services: Services) { return summarize(listStock(services), services.reservations.activeCount()); }
