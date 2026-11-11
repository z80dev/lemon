import { loadConfig } from './load.ts';
import type { Config, Channel } from './types.ts';
export function fromEnvironment(env: Record<string, string | undefined>): Config {
  return loadConfig({ deliveryChannel: (env.HARBOR_DELIVERY_CHANNEL ?? 'email') as Channel,
    batchSize: env.HARBOR_BATCH_SIZE === undefined ? 25 : Number(env.HARBOR_BATCH_SIZE), sender: env.HARBOR_SENDER ?? 'harbor' });
}
