import { conflict, missing } from '../errors.ts';
export type Reservation = { reservationId: string; sku: string; quantity: number; status: 'active' | 'cancelled' | 'fulfilled' };
export class ReservationBook {
  #rows = new Map<string, Reservation>();
  ensureUnused(id: string): void { if (this.#rows.has(id)) conflict('reservationId already exists'); }
  create(id: string, sku: string, quantity: number): Reservation {
    const row: Reservation = { reservationId: id, sku, quantity, status: 'active' };
    this.#rows.set(id, row); return { ...row };
  }
  get(id: string): Reservation {
    const row = this.#rows.get(id); if (!row) return missing('reservation not found'); return { ...row };
  }
  setStatus(id: string, status: Reservation['status']): Reservation {
    const row = this.#rows.get(id)!; row.status = status; return { ...row };
  }
  activeCount(): number { return [...this.#rows.values()].filter(row => row.status === 'active').length; }
}
