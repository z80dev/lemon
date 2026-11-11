import { ListenerRegistry } from './registry.ts';
import type { Hub } from './types.ts';
export type { Hub, SubscribeOptions } from './types.ts';

export function createHub<Events extends object>(): Hub<Events> {
  const registry = new ListenerRegistry<keyof Events>();
  return {
    subscribe(key, listener, options = {}) {
      // The keyed public API guarantees that this registration receives Events[K].
      const registration = registry.add(key, payload => listener(payload as Events[typeof key]), options.once ?? false);
      return () => registry.remove(key, registration);
    },
    publish(key, payload) {
      const errors: unknown[] = [];
      for (const registration of registry.snapshot(key)) {
        if (!registration.active) continue;
        if (registration.once) registry.remove(key, registration);
        try { registration.invoke(payload); } catch (error) { errors.push(error); }
      }
      if (errors.length > 0) throw new AggregateError(errors, 'listeners failed');
    },
    listenerCount(key) { return registry.count(key); },
  };
}
