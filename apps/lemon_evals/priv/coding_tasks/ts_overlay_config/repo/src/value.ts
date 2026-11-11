export type ConfigValue = string | number | boolean | null | ConfigValue[] | ConfigObject;
export interface ConfigObject { [key: string]: ConfigValue }
export const DELETE: unique symbol = Symbol("delete configuration property");
export type PatchValue = string | number | boolean | null | readonly ConfigValue[] | ConfigPatch | typeof DELETE | undefined;
export interface ConfigPatch { readonly [key: string]: PatchValue }

export function isObject(value: unknown): value is ConfigObject {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function cloneValue(value: ConfigValue): ConfigValue {
  if (Array.isArray(value)) return value.map(cloneValue);
  if (isObject(value)) return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, cloneValue(item)]));
  return value;
}
