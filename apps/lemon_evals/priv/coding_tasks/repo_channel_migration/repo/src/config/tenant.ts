import { loadConfig } from './load.ts';
import type { Config, ConfigInput } from './types.ts';
export function tenantConfig(base: Config, overrides: ConfigInput): Config {
  return loadConfig({ ...base, ...overrides });
}
