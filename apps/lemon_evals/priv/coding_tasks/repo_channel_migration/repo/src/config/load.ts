import { defaults } from './defaults.ts';
import { validate } from './validate.ts';
import type { Config, ConfigInput } from './types.ts';
export function loadConfig(input: ConfigInput = {}): Config {
  for (const key of Object.keys(input)) {
    if (!['deliveryChannel', 'batchSize', 'sender'].includes(key)) throw new Error(`unsupported config key: ${key}`);
  }
  return validate({ ...defaults, ...input });
}
