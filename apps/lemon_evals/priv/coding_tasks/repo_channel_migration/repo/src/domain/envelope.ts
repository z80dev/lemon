import type { Config } from '../config/types.ts';
import type { Message } from './message.ts';
export type Envelope = { id: string; destination: string; body: string; channel: string; sender: string };
export function envelope(config: Config, item: Message, body: string): Envelope {
  return { id: item.id, destination: item.recipient, body, channel: config.deliveryChannel, sender: config.sender };
}
