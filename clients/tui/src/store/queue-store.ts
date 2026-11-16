/**
 * The client-side prompt queue.
 *
 * A prompt submitted while a run is in flight (in `queue` mode) is held here
 * and **never leaves the process** until the run ends: that is the whole point.
 * The daemon has its own `followup` queue, but a queued prompt parked there is
 * no longer editable, and the editable queue is the feature — the user can
 * reorder their mind before the agent gets a chance to read it.
 *
 * Local and daemon-owned states are distinguished because they fail differently:
 *   `queued-local`       waiting for the session's run to finish; ours to send.
 *   `waiting-connection` mirror of a `chat.send` the protocol client parked
 *                        while offline (see {@link ControlPlaneClient.queued}).
 *                        That one is already out of our hands — the client
 *                        flushes it on reconnect — so it is shown, not edited.
 *   `needs-review`       a send may already have taken effect; requires an
 *                        explicit edit/review and is never automatically drained.
 *   `accepted-steer`     journaled by the daemon; deletion must be acknowledged
 *                        by its withdrawal RPC before this client removes it.
 *
 * The store is per session key: switching sessions must not hand one session's
 * backlog to another, and a background session whose run finishes drains its
 * own queue.
 */

import type { PendingImage } from "../composer/images.ts";
import { Emitter } from "./events.ts";

export type QueueItemState =
	| "queued-local"
	| "waiting-connection"
	| "needs-review"
	| "accepted-steer";

export interface QueueItem {
	/** Unique across the process; stable while the item sits in the queue. */
	id: string;
	text: string;
	attachments?: readonly PendingImage[];
	/** A possibly committed send: inspect this identity, never auto-replay it. */
	submission?: { requestId: string; runId?: string };
	/** Daemon-owned input: never edit or replay it as a local queued prompt. */
	steer?: { messageId: string };
	state: QueueItemState;
	/** Wall-clock ms when the item was queued. */
	at: number;
}

export interface QueueStoreEventMap {
	/** Any mutation to one session's queue. */
	changed: { sessionKey: string; length: number };
}

let queueSeq = 0;

function nextQueueId(): string {
	queueSeq += 1;
	return `q-${queueSeq}`;
}

/** Test hook: make queue ids deterministic across cases. */
export function resetQueueIds(): void {
	queueSeq = 0;
}

export class QueueStore {
	readonly events = new Emitter<QueueStoreEventMap>();

	readonly #bySession = new Map<string, QueueItem[]>();

	// -- reads ---------------------------------------------------------------

	/** This session's backlog, head first. Empty sessions never allocate. */
	items(sessionKey: string): readonly QueueItem[] {
		return this.#bySession.get(sessionKey) ?? EMPTY;
	}

	length(sessionKey: string): number {
		return this.#bySession.get(sessionKey)?.length ?? 0;
	}

	/** Queued prompts across every session — what the status line counts. */
	total(): number {
		let total = 0;
		for (const items of this.#bySession.values()) total += items.length;
		return total;
	}

	/** Sessions with a non-empty queue, for `/queue` and the switcher. */
	sessionKeys(): string[] {
		const keys: string[] = [];
		for (const [key, items] of this.#bySession) if (items.length > 0) keys.push(key);
		return keys;
	}

	find(sessionKey: string, id: string): QueueItem | undefined {
		return this.#bySession.get(sessionKey)?.find((item) => item.id === id);
	}

	// -- writes --------------------------------------------------------------

	/** Append a prompt. Blank text is not a prompt and is ignored. */
	push(
		sessionKey: string,
		text: string,
		state: QueueItemState = "queued-local",
		attachments: readonly PendingImage[] = [],
	): QueueItem | undefined {
		if (text.trim().length === 0 && attachments.length === 0) return undefined;
		const item: QueueItem = {
			id: nextQueueId(),
			text,
			state,
			at: Date.now(),
			...(attachments.length ? { attachments } : {}),
		};
		const items = this.#listFor(sessionKey);
		const firstSteer = items.findIndex((queued) => queued.state === "accepted-steer");
		if (firstSteer < 0) items.push(item);
		else items.splice(firstSteer, 0, item);
		this.#changed(sessionKey);
		return item;
	}

	/** A refused/uncertain send stays inspectable, but must not auto-retry. */
	restoreForReview(sessionKey: string, item: QueueItem): void {
		this.#listFor(sessionKey).unshift({ ...item, state: "needs-review" });
		this.#changed(sessionKey);
	}

	/** Mirror a journaled steer without taking ownership of its delivery. */
	acceptSteer(sessionKey: string, messageId: string, text: string): void {
		const items = this.#listFor(sessionKey);
		const index = items.findIndex((item) => item.steer?.messageId === messageId);
		const previous = items[index];
		const item: QueueItem = {
			id: previous?.id ?? nextQueueId(),
			text,
			at: previous?.at ?? Date.now(),
			state: "accepted-steer",
			steer: { messageId },
		};
		if (index < 0) items.push(item);
		else items[index] = item;
		this.#changed(sessionKey);
	}

	/** A complete read may prune old steers; a bounded partial read never may. */
	reconcileSteers(
		sessionKey: string,
		steers: readonly { messageId: string; preview: string }[],
		truncated: boolean,
	): void {
		const previous = this.items(sessionKey);
		const byId = new Map(
			previous.flatMap((item) => (item.steer ? [[item.steer.messageId, item] as const] : [])),
		);
		const ids = new Set(steers.map((steer) => steer.messageId));
		const kept = previous.filter(
			(item) =>
				!item.steer ||
				((truncated || item.submission !== undefined) && !ids.has(item.steer.messageId)),
		);
		for (const steer of steers) {
			const old = byId.get(steer.messageId);
			kept.push({
				id: old?.id ?? nextQueueId(),
				text: old?.text ?? steer.preview,
				at: old?.at ?? Date.now(),
				state: "accepted-steer",
				steer: { messageId: steer.messageId },
			});
		}
		this.#bySession.set(sessionKey, kept);
		this.#changed(sessionKey);
	}

	/** Take the head — what a finished run pops and sends. */
	shift(sessionKey: string): QueueItem | undefined {
		const items = this.#bySession.get(sessionKey);
		if (!items || items.length === 0) return undefined;
		const item = items.shift();
		this.#changed(sessionKey);
		return item;
	}

	/** Drop one item (the panel's `d`, or an edit that pulls it into the editor). */
	remove(sessionKey: string, id: string): QueueItem | undefined {
		const items = this.#bySession.get(sessionKey);
		if (!items) return undefined;
		const index = items.findIndex((item) => item.id === id);
		if (index < 0) return undefined;
		const [item] = items.splice(index, 1);
		this.#changed(sessionKey);
		return item;
	}

	/** Rewrite an item in place, keeping its position in the queue. */
	replace(sessionKey: string, id: string, text: string): QueueItem | undefined {
		const item = this.find(sessionKey, id);
		if (!item) return undefined;
		if (text.trim().length === 0 && !item.attachments?.length) return this.remove(sessionKey, id);
		item.text = text;
		this.#changed(sessionKey);
		return item;
	}

	clear(sessionKey: string): void {
		const items = this.#bySession.get(sessionKey);
		if (!items || items.length === 0) return;
		items.length = 0;
		this.#changed(sessionKey);
	}

	// -- internals -----------------------------------------------------------

	#listFor(sessionKey: string): QueueItem[] {
		let items = this.#bySession.get(sessionKey);
		if (!items) {
			items = [];
			this.#bySession.set(sessionKey, items);
		}
		return items;
	}

	#changed(sessionKey: string): void {
		this.events.emit("changed", { sessionKey, length: this.length(sessionKey) });
	}
}

const EMPTY: readonly QueueItem[] = Object.freeze([]);
