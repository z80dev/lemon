type Entry<V> = { value: V; expiresAt: number };
export class ExpiringCache<V> {
  private entries = new Map<string, Entry<V>>();
  private capacity: number;
  private now: () => number;
  constructor(capacity: number, now: () => number = Date.now) {
    if (!Number.isInteger(capacity) || capacity <= 0) throw new RangeError('capacity');
    this.capacity = capacity;
    this.now = now;
  }
  private purge(time: number): void {
    for (const [key, entry] of this.entries) if (entry.expiresAt <= time) this.entries.delete(key);
  }
  set(key: string, value: V, ttlMs: number): void {
    const time = this.now();
    if (!Number.isFinite(ttlMs) || ttlMs < 0) throw new RangeError('ttlMs');
    this.purge(time);
    this.entries.delete(key);
    if (ttlMs === 0) return;
    this.entries.set(key, {value, expiresAt: time + ttlMs});
    if (this.entries.size > this.capacity) this.entries.delete(this.entries.keys().next().value!);
  }
  get(key: string): V | undefined {
    this.purge(this.now());
    const entry = this.entries.get(key);
    if (!entry) return undefined;
    this.entries.delete(key);
    this.entries.set(key, entry);
    return entry.value;
  }
  has(key: string): boolean { this.purge(this.now()); return this.entries.has(key); }
  get size(): number { this.purge(this.now()); return this.entries.size; }
}
