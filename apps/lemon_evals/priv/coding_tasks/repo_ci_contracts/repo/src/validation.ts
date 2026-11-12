import { invalid } from './errors.ts';
export function sku(value: unknown): string {
  if (typeof value !== 'string' || !value.trim()) return invalid('sku must be nonempty');
  return value.trim().toUpperCase();
}
export function reservationId(value: unknown): string {
  if (typeof value !== 'string' || !value.trim()) return invalid('reservationId must be nonempty');
  return value.trim();
}
export function quantity(value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) return invalid('quantity must be a positive integer');
  return value;
}
