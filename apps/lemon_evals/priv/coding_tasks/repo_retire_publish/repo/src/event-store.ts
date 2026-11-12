import type { Event } from './types.ts';
export class EventStore {
  #events: Event[] = [];
  append(event: Event): void { this.#events.push(structuredClone(event)); }
  snapshot(): Event[] { return structuredClone(this.#events); }
  get size(): number { return this.#events.length; }
}
