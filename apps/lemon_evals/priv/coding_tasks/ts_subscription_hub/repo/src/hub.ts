import { ListenerRegistry } from './registry.ts';
import type { Hub } from './types.ts';
export type { Hub, SubscribeOptions } from './types.ts';

export function createHub<Events extends object>(): Hub<Events> {
  const registry = new ListenerRegistry<keyof Events>();
  return {
    subscribe(key, listener, options = {}) {
      const registration = registry.add(key, payload => listener(payload as Events[typeof key]), options.once ?? false);
      return () => registry.remove(key, registration);
    },
    publish(key, payload) {
      for (const registration of registry.snapshot(key)) {
        registration.invoke(payload);
        if (registration.once) registry.remove(key, registration);
      }
    },
    listenerCount(key) { return registry.count(key); },
  };
}
