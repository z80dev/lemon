import { loadConfig } from '../config/load.ts';
import type { Channel } from '../config/types.ts';
export function options(args: string[]) {
  let deliveryChannel: Channel = 'email'; let text = 'hello'; let recipient = 'reader@example.test';
  for (let i = 0; i < args.length; i += 2) {
    const value = args[i + 1];
    if (value === undefined) throw new Error(`missing value for ${args[i]}`);
    switch (args[i]) { case '--delivery-channel': deliveryChannel = value as Channel; break; case '--message': text = value; break; case '--recipient': recipient = value; break; default: throw new Error(`unsupported flag: ${args[i]}`); }
  }
  if (deliveryChannel === 'sms' && recipient === 'reader@example.test') recipient = '+15551234567';
  if (deliveryChannel === 'webhook' && recipient === 'reader@example.test') recipient = 'https://hooks.example.test/inbox';
  return { config: loadConfig({ deliveryChannel }), text, recipient };
}
