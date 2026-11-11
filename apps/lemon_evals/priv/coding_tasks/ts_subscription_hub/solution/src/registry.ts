export interface Registration {
  invoke: (payload: unknown) => void;
  once: boolean;
  active: boolean;
}

export class ListenerRegistry<Key extends PropertyKey> {
  private buckets = new Map<Key, Set<Registration>>();

  add(key: Key, invoke: (payload: unknown) => void, once: boolean): Registration {
    const registration: Registration = { invoke, once, active: true };
    let bucket = this.buckets.get(key);
    if (!bucket) { bucket = new Set(); this.buckets.set(key, bucket); }
    bucket.add(registration);
    return registration;
  }

  remove(key: Key, registration: Registration): void {
    if (!registration.active) return;
    registration.active = false;
    const bucket = this.buckets.get(key);
    bucket?.delete(registration);
    if (bucket?.size === 0) this.buckets.delete(key);
  }

  snapshot(key: Key): readonly Registration[] { return [...(this.buckets.get(key) ?? [])]; }
  count(key: Key): number { return this.buckets.get(key)?.size ?? 0; }
}
