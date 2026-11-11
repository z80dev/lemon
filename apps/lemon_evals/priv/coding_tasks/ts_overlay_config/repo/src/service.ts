import { mergeConfig } from './merge.ts';
import type { ConfigObject, ConfigPatch } from './value.ts';

export interface ConfigSource {
  defaults: ConfigObject;
  environments: Record<string, ConfigPatch>;
}

export function resolveServiceConfig(source: ConfigSource, environment: string, overrides: ConfigPatch = {}): ConfigObject {
  if (!Object.hasOwn(source.environments, environment)) throw new RangeError('Unknown environment: ' + environment);
  return mergeConfig(source.defaults, source.environments[environment], overrides);
}
