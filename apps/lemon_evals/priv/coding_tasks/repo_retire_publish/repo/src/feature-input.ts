export function text(value: string, field: string): string {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`${field} must be nonempty`);
  return value.trim();
}
export function positive(value: number, field: string): number {
  if (!Number.isInteger(value) || value <= 0) throw new Error(`${field} must be a positive integer`);
  return value;
}
export function email(value: string): string {
  const normalized = text(value, 'email').toLowerCase();
  if (!normalized.includes('@')) throw new Error('email must contain @');
  return normalized;
}
