import type { Stock } from './stock.ts';
export function summarize(rows: Stock[], activeReservations: number) {
  return { skus: rows.length, onHand: rows.reduce((n, row) => n + row.onHand, 0),
    reserved: rows.reduce((n, row) => n + row.reserved, 0), available: rows.reduce((n, row) => n + row.available, 0), activeReservations };
}
