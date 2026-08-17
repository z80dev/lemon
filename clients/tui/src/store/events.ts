/**
 * Minimal typed event emitter.
 *
 * Deliberately dependency-free and synchronous: controllers use it for coarse
 * notifications (connection changed, session changed, approvals changed) and
 * the protocol client uses it to demux server event frames. A listener that
 * throws must not take down the emit loop — the error is routed to `onError`
 * (default: rethrow on a fresh macrotask so it surfaces without corrupting the
 * caller's control flow).
 */

export type Listener<T> = (payload: T) => void;

/**
 * Map of event name -> payload type.
 *
 * Deliberately `object` rather than `Record<string, unknown>`: interfaces do not
 * get an implicit index signature, so the tighter constraint would reject every
 * hand-written event map.
 */
export type EventMap = object;

export interface EmitterOptions {
	/** Called when a listener throws. Defaults to reporting asynchronously. */
	onError?: (error: unknown, event: string) => void;
}

function defaultOnError(error: unknown, event: string): void {
	// Rethrow out of band: never let one bad listener abort the emit loop, and
	// never swallow the failure either.
	queueMicrotask(() => {
		if (error instanceof Error) {
			error.message = `[emitter:${event}] ${error.message}`;
			throw error;
		}
		throw new Error(`[emitter:${event}] ${String(error)}`);
	});
}

export class Emitter<Events extends EventMap> {
	readonly #listeners = new Map<keyof Events, Set<Listener<any>>>();
	readonly #onError: (error: unknown, event: string) => void;

	constructor(options: EmitterOptions = {}) {
		this.#onError = options.onError ?? defaultOnError;
	}

	/** Subscribe. Returns an unsubscribe function. */
	on<K extends keyof Events & string>(event: K, listener: Listener<Events[K]>): () => void {
		let set = this.#listeners.get(event);
		if (!set) {
			set = new Set();
			this.#listeners.set(event, set);
		}
		set.add(listener);
		return () => {
			this.off(event, listener);
		};
	}

	/** Subscribe for a single emission. Returns an unsubscribe function. */
	once<K extends keyof Events & string>(event: K, listener: Listener<Events[K]>): () => void {
		const wrapped: Listener<Events[K]> = (payload) => {
			off();
			listener(payload);
		};
		const off = this.on(event, wrapped);
		return off;
	}

	off<K extends keyof Events & string>(event: K, listener: Listener<Events[K]>): void {
		const set = this.#listeners.get(event);
		if (!set) return;
		set.delete(listener);
		if (set.size === 0) this.#listeners.delete(event);
	}

	emit<K extends keyof Events & string>(event: K, payload: Events[K]): void {
		const set = this.#listeners.get(event);
		if (!set || set.size === 0) return;
		// Copy: listeners may unsubscribe (or subscribe) during dispatch.
		for (const listener of [...set]) {
			try {
				listener(payload);
			} catch (error) {
				this.#onError(error, event);
			}
		}
	}

	listenerCount(event: keyof Events & string): number {
		return this.#listeners.get(event)?.size ?? 0;
	}

	removeAllListeners(event?: keyof Events & string): void {
		if (event === undefined) {
			this.#listeners.clear();
			return;
		}
		this.#listeners.delete(event);
	}

	/** Resolve on the next emission of `event`. */
	waitFor<K extends keyof Events & string>(event: K, timeoutMs?: number): Promise<Events[K]> {
		return new Promise<Events[K]>((resolve, reject) => {
			let timer: ReturnType<typeof setTimeout> | undefined;
			const off = this.once(event, (payload) => {
				if (timer) clearTimeout(timer);
				resolve(payload);
			});
			if (timeoutMs !== undefined) {
				timer = setTimeout(() => {
					off();
					reject(new Error(`Timed out waiting for "${event}" after ${timeoutMs}ms`));
				}, timeoutMs);
				timer.unref?.();
			}
		});
	}
}
