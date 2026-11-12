import { EventBuffer } from "./buffer.js";
import { Totals } from "./totals.js";
import { validKey, validTime, validValue } from "./validation.js";

export class WindowIndex {
  clock = 0;
  windowMs;
  buffer;
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
    this.buffer.append({ at, key, value });
  }
  advance(now) {
    validTime(now, this.clock);
    this.clock = now;
    this.buffer.evict(now - this.windowMs, () => {});
  }
  rebuild() {
    const totals = new Totals;
    this.buffer.forEach((event) => totals.add(event));
    return totals;
  }
  get(key) {
    validKey(key);
    return this.rebuild().get(key);
  }
  snapshot() {
    return this.rebuild().snapshot();
  }
}
