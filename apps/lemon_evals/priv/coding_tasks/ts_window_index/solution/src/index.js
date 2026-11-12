import { EventBuffer } from "./buffer.js";
import { Totals } from "./totals.js";
import { validKey, validTime, validValue } from "./validation.js";

export class WindowIndex {
  clock = 0;
  windowMs;
  buffer;
  totals = new Totals;
  constructor(windowMs, onVisit = () => {}) {
    if (!Number.isSafeInteger(windowMs) || windowMs <= 0)
      throw new RangeError("Invalid window");
    this.windowMs = windowMs;
    this.buffer = new EventBuffer(onVisit);
  }
  get now() {
    return this.clock;
  }
  append(at, key, value) {
    validTime(at, this.clock);
    validKey(key);
    validValue(value);
    this.advance(at);
    const event = { at, key, value };
    this.buffer.append(event);
    this.totals.add(event);
  }
  advance(now) {
    validTime(now, this.clock);
    this.clock = now;
    this.buffer.evict(now - this.windowMs, (event) => this.totals.remove(event));
  }
  get(key) {
    validKey(key);
    return this.totals.get(key);
  }
  snapshot() {
    return this.totals.snapshot();
  }
}
