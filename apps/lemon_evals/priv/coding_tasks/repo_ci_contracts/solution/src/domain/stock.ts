import { missing, conflict } from '../errors.ts';
export type Stock = { sku: string; onHand: number; reserved: number; available: number };
export class StockLedger {
  #rows = new Map<string, { onHand: number; reserved: number }>();
  add(sku: string, quantity: number): Stock {
    const row = this.#rows.get(sku) ?? { onHand: 0, reserved: 0 };
    row.onHand += quantity; this.#rows.set(sku, row); return this.get(sku);
  }
  get(sku: string): Stock {
    const row = this.#rows.get(sku); if (!row) return missing('sku not found');
    return { sku, ...row, available: row.onHand - row.reserved };
  }
  reserve(sku: string, quantity: number): void {
    const current = this.get(sku);
    if (current.available < quantity) return conflict('insufficient stock');
    this.#rows.get(sku)!.reserved += quantity;
  }
  release(sku: string, quantity: number): void { this.#rows.get(sku)!.reserved -= quantity; }
  fulfill(sku: string, quantity: number): void {
    const row = this.#rows.get(sku)!; row.onHand -= quantity; row.reserved -= quantity;
  }
}
