import type { Envelope } from './envelope.ts';
export type Receipt = { id: string; channel: string; status: 'queued'; destination: string };
export function receipt(item: Envelope): Receipt { return { id: item.id, channel: item.channel, status: 'queued', destination: item.destination }; }
