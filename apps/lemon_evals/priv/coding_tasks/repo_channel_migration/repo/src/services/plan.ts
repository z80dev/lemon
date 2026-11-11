import type { Config } from '../config/types.ts';
import type { Message } from '../domain/message.ts';
import { partitions } from '../routing/partition.ts';
import { retryPolicy } from '../routing/retry.ts';
import { prepare } from './prepare.ts';
export function plan(config: Config, items: Message[]) {
  return { channel: config.deliveryChannel, retry: retryPolicy(config), batches: partitions(config, items).map(group => group.map(item => prepare(config, item))) };
}
