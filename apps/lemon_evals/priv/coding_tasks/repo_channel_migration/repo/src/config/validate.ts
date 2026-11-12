import type { Config, Channel } from './types.ts';
export function validate(config: Config): Config {
  if (!['email', 'sms', 'webhook'].includes(config.deliveryChannel)) throw new Error('channel must be email, sms or webhook');
  if (!Number.isInteger(config.batchSize) || config.batchSize < 1 || config.batchSize > 100) throw new Error('batchSize must be an integer from 1 to 100');
  if (typeof config.sender !== 'string' || !config.sender.trim()) throw new Error('sender must be nonempty');
  return { deliveryChannel: config.deliveryChannel as Channel, batchSize: config.batchSize, sender: config.sender.trim() };
}
