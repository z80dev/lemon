import type { DispatchRequest, DispatchReceipt, Event } from './types.ts';
import { validateRequest } from './validation.ts';
import { identity } from './identity.ts';
import { EventStore } from './event-store.ts';
import { accepted, duplicate } from './receipts.ts';
export type { LegacyPublisher } from './types.ts';
export class EventBus {
  #store = new EventStore();
  #keys = new Map<string, string>();
  dispatch(request: DispatchRequest): DispatchReceipt {
    validateRequest(request);
    const key = identity(request);
    const existing = this.#keys.get(key);
    if (existing !== undefined) return duplicate(existing);
    const id = `evt-${this.#store.size + 1}`;
    this.#store.append({ ...request, id });
    this.#keys.set(key, id);
    return accepted(id);
  }
  publish(topic: string, payload: Record<string, unknown>): string {
    return this.dispatch({ tenantId: 'legacy', actorId: 'system', key: `legacy-${this.#store.size + 1}`, topic, payload }).id;
  }
  snapshot(): Event[] { return this.#store.snapshot(); }
  get size(): number { return this.#store.size; }
}
export function publish(bus: EventBus, topic: string, payload: Record<string, unknown>): string { return bus.publish(topic, payload); }
