export function validTime(value, minimum) {
  if (!Number.isSafeInteger(value) || value < minimum)
    throw new RangeError("Invalid time");
}
export function validKey(key) {
  if (typeof key !== "string" || key.length === 0)
    throw new TypeError("Invalid key");
}
export function validValue(value) {
  if (!Number.isSafeInteger(value))
    throw new TypeError("Invalid value");
}
