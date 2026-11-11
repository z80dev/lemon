# Monitoring subscription hub

Implement the keyed synchronous subscription library used by src/monitor.ts. Preserve the public types and factory exported from src/hub.ts; the registry is internal and may be changed.

## Public API

createHub<Events extends object>(): Hub<Events>

Hub<Events> exposes:
- subscribe<K extends keyof Events>(key: K, listener: (payload: Events[K]) => void, options?: { once?: boolean }): () => void
- publish<K extends keyof Events>(key: K, payload: Events[K]): void
- listenerCount<K extends keyof Events>(key: K): number

Keys and payload types must remain correlated in the TypeScript API: an interface with reading and alarm events must not accept an unknown event or the wrong payload for a known event. All syntax must be erasable by Node 22. String, number, and symbol keys are supported and distinct (1 and "1" are different). Keys such as __proto__ are literal event keys. Each hub is independent. Payloads are passed synchronously by identity without cloning or modification; listener return values are ignored. Listeners are synchronous; awaiting promises is outside this API.

## Dispatch and lifetime

Every subscribe creates an independent registration, even for the same key and callback. Callbacks run in registration order for that key. The returned unsubscribe function is idempotent and may be called detached. listenerCount reports active registrations only, immediately reflecting all subscription, unsubscription, and once-consumption changes. Publishing an empty key is a no-op.

Each publish snapshots the registrations present at its entry. New registrations are excluded from that dispatch. Before each snapshot entry is invoked, check that it is still active: a registration removed before its turn is skipped. Removing and re-registering the same callback creates a new registration, not a revival of the old snapshot entry.

A once registration is removed BEFORE its callback runs, even if that callback throws. It is invoked at most once overall, including under recursive publishing. Explicit once: false behaves like omitted options. An unsubscribe captured for an already consumed once registration remains harmless.

Nested publishing is allowed and runs synchronously to completion before the caller continues. Each nested publish takes a fresh snapshot of the currently active registrations. Once listeners consumed in a nested dispatch must be skipped by an outer dispatch still holding their snapshot entry. Subscriptions added during an outer callback can therefore participate in a nested publish but not in that original outer snapshot.

## Listener failures

Catch every thrown listener value, including undefined, null, strings, and Error instances; continue invoking all other eligible listeners in that dispatch. If any callbacks threw, throw a standard AggregateError after dispatch finishes, with message "listeners failed" and errors in invocation order, preserving each thrown value's identity. A nested publish's AggregateError is one thrown value in its caller's dispatch; do not flatten it. No error is thrown for an error-free dispatch. Listener failures must not corrupt registration state or prevent later publishing.

## Monitoring clients

MonitorEvents maps reading to { sensor: string; value: number } and alarm to { sensor: string; value: number; limit: number }. attachAlarmRule(hub, limit) subscribes to reading and publishes alarm only when value > limit, preserving sensor/value and adding limit. It returns the reading unsubscribe function. collectAlarms(hub) returns { alarms, stop }, appends alarm payloads in delivery order, and stops collecting after stop() (which is idempotent). These clients must continue to work with the completed hub, including nested dispatch and unsubscription.

No dependencies or network access are needed. Run node --test test/*.test.ts on Node 22.
