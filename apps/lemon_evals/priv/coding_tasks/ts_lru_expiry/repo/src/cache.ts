type Entry<V> = { value: V; expiresAt: number };
export class ExpiringCache<V> {
  private entries = new Map<string, Entry<V>>();
  constructor(privateCapacity: number, privateClock: () => number = Date.now) {
    this.capacity = privateCapacity;
    this.now = privateClock;
  }
  private capacity: number;
  private now: () => number;
  set(key: string, value: V, ttlMs: number): void {
    if (this.entries.size >= this.capacity) this.entries.delete(this.entries.keys().next().value!);
    this.entries.set(key, {value, expiresAt: this.now() + ttlMs});
  }
  get(key: string): V | undefined {
    const item = this.entries.get(key);
    if (!item || item.expiresAt < this.now()) return undefined;
    this.entries.delete(key);
    this.entries.set(key, item);
    return item.value;
  }
  has(key: string): boolean { return this.get(key) !== undefined; }
  get size(): number { return this.entries.size; }
}
