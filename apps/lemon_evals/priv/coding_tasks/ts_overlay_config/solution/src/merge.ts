import { cloneValue, DELETE, isObject } from './value.ts';
import type { ConfigObject, ConfigPatch, ConfigValue } from './value.ts';
export { DELETE } from './value.ts';

function mergeInto(result: ConfigObject, overlay: ConfigPatch): void {
  for (const [key, patch] of Object.entries(overlay)) {
    if (patch === undefined) continue;
    if (patch === DELETE) { delete result[key]; continue; }
    let next: ConfigValue;
    if (isObject(patch)) {
      const previous = Object.hasOwn(result, key) ? result[key] : undefined;
      next = isObject(previous) ? previous : {};
      mergeInto(next as ConfigObject, patch as ConfigPatch);
    } else {
      next = cloneValue(patch as ConfigValue);
    }
    Object.defineProperty(result, key, { value: next, enumerable: true, configurable: true, writable: true });
  }
}

export function mergeConfig(base: ConfigObject, ...overlays: ConfigPatch[]): ConfigObject {
  const result = cloneValue(base) as ConfigObject;
  for (const overlay of overlays) mergeInto(result, overlay);
  return result;
}
