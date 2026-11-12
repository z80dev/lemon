import type { ConfigObject, ConfigPatch } from './value.ts';
export { DELETE } from './value.ts';

export function mergeConfig(base: ConfigObject, ...overlays: ConfigPatch[]): ConfigObject {
  return Object.assign({}, base, ...overlays) as ConfigObject;
}
