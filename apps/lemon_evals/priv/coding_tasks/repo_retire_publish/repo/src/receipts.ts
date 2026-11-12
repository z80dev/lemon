import type { DispatchReceipt } from './types.ts';
export function accepted(id: string): DispatchReceipt { return { id, accepted: true }; }
export function duplicate(id: string): DispatchReceipt { return { id, accepted: false }; }
