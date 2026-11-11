import type { Config } from '../config/types.ts';
import type { Message } from '../domain/message.ts';
export function partitions(config: Config, items: Message[]): Message[][] {
  const size = config.deliveryChannel === 'sms' ? Math.min(config.batchSize, 10) : config.batchSize;
  const groups: Message[][] = [];
  for (let offset = 0; offset < items.length; offset += size) groups.push(items.slice(offset, offset + size));
  return groups;
}
