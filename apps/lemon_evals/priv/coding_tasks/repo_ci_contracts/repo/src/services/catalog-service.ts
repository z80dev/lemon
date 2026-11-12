import type { Services } from '../types.ts';
export function listStock(services: Services) { return services.catalog.list().map(sku => services.stock.get(sku)); }
