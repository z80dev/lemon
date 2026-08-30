/**
 * Client-wide state: connection, sessions, models, approvals.
 *
 * Sessions are created lazily — an event for an unknown key materializes its
 * store, so background sessions accumulate transcript and unread counts without
 * anyone having switched to them yet (P6 renders that switcher).
 *
 * Coarse notifications go out on {@link AppStore.events}; fine-grained UI
 * updates are the controllers' business, not the store's.
 */

import type {
	ApprovalRequestedEvent,
	ConnectionState,
	ModelsListResult,
} from "../protocol/types.ts";
import { Emitter } from "./events.ts";
import { QueueStore } from "./queue-store.ts";
import { SessionStore } from "./session-store.ts";
import type { ApprovalBlock } from "./transcript-model.ts";

export interface AppStoreEventMap {
	"conn-changed": { state: ConnectionState };
	"session-changed": { key: string };
	"approvals-changed": { pending: number };
	/** A session's block list grew or mutated; the UI may need a full render. */
	"blocks-changed": { key: string };
	/** The default submission mode changed (`/mode`). */
	"mode-changed": { mode: SubmissionMode };
}

/**
 * What happens to a prompt submitted while a run is in flight:
 *
 *   `queue`      hold it in the {@link QueueStore} and send it when the run
 *                ends — it never reaches the daemon before then, which is what
 *                keeps it editable;
 *   `steer`      send it into the running turn (`chat.send queueMode: steer`);
 *   `redirect`   replace the model's pending direction while preserving
 *                completed tool work (`queueMode: redirect`);
 *   `interrupt`  stop the run and send it (`queueMode: interrupt`).
 *
 * The setting is the default; Alt+Enter overrides it for one submission.
 */
export type SubmissionMode = "queue" | "steer" | "redirect" | "interrupt";

export interface PendingApproval {
	event: ApprovalRequestedEvent;
	block?: ApprovalBlock;
}

export class AppStore {
	readonly events = new Emitter<AppStoreEventMap>();
	readonly sessions = new Map<string, SessionStore>();
	readonly approvals = new Map<string, PendingApproval>();
	/**
	 * Unsent editor text, per session. A switch parks the outgoing session's
	 * draft here and takes the incoming one back out, so a half-typed prompt
	 * survives a trip to another session instead of following the user around.
	 */
	readonly drafts = new Map<string, string>();
	/** Prompts held client-side while a run is in flight, per session. */
	readonly queue = new QueueStore();

	connection: ConnectionState = "offline";
	serverVersion: string | undefined;
	/** Methods the daemon advertised in `hello-ok.features.methods`. */
	methods = new Set<string>();
	models: ModelsListResult["models"] = [];
	/** When {@link models} was last fetched; 0 means never. */
	modelsFetchedAtMs = 0;
	/** What a submission does while a run is in flight. Owned by `/mode`. */
	submissionMode: SubmissionMode = "queue";
	/** Latest `usage.status` payload, for the status bar's context gauge. */
	usage: Record<string, unknown> | undefined;

	#focusedKey: string;

	constructor(focusedKey: string) {
		this.#focusedKey = focusedKey;
		this.session(focusedKey).focused = true;
	}

	get focusedKey(): string {
		return this.#focusedKey;
	}

	/** The focused session, created if this is the first mention of it. */
	get focused(): SessionStore {
		return this.session(this.#focusedKey);
	}

	/** Lazily materialize a session store. */
	session(key: string): SessionStore {
		let store = this.sessions.get(key);
		if (!store) {
			store = new SessionStore(key);
			this.sessions.set(key, store);
		}
		return store;
	}

	setFocused(key: string): SessionStore {
		const next = this.session(key);
		if (this.#focusedKey === key) {
			next.markRead();
			return next;
		}
		const previous = this.sessions.get(this.#focusedKey);
		if (previous) previous.focused = false;
		this.#focusedKey = key;
		next.focused = true;
		next.markRead();
		this.events.emit("session-changed", { key });
		return next;
	}

	setSubmissionMode(mode: SubmissionMode): void {
		if (this.submissionMode === mode) return;
		this.submissionMode = mode;
		this.events.emit("mode-changed", { mode });
	}

	setConnection(state: ConnectionState): void {
		if (this.connection === state) return;
		this.connection = state;
		this.events.emit("conn-changed", { state });
	}

	addApproval(event: ApprovalRequestedEvent, block?: ApprovalBlock): void {
		this.approvals.set(event.approvalId, { event, block });
		this.events.emit("approvals-changed", { pending: this.approvals.size });
	}

	resolveApproval(approvalId: string, decision?: string): PendingApproval | undefined {
		const pending = this.approvals.get(approvalId);
		if (!pending) return undefined;
		this.approvals.delete(approvalId);
		if (pending.block) {
			pending.block.status = "resolved";
			pending.block.decision = decision;
		}
		this.events.emit("approvals-changed", { pending: this.approvals.size });
		return pending;
	}

	get pendingApprovals(): number {
		return this.approvals.size;
	}

	/** Unread blocks across every session that is not on screen. */
	totalUnread(): number {
		let total = 0;
		for (const session of this.sessions.values()) {
			if (session.key !== this.#focusedKey) total += session.unread;
		}
		return total;
	}

	/**
	 * Sessions with a run in flight, on screen or not. The status line shows this
	 * next to the session count: work continuing in a session the user is not
	 * looking at is exactly the thing a single-session status line hides.
	 */
	busySessions(): number {
		let busy = 0;
		for (const session of this.sessions.values()) {
			if (session.busy) busy += 1;
		}
		return busy;
	}

	/** Park the editor's text for a session (empty drafts are forgotten). */
	setDraft(key: string, text: string): void {
		if (text.length === 0) this.drafts.delete(key);
		else this.drafts.set(key, text);
	}

	/** Take a session's parked draft back out; sessions with none get "". */
	takeDraft(key: string): string {
		return this.drafts.get(key) ?? "";
	}

	/** Forget a session entirely: transcript, draft, and focus if it had it. */
	forgetSession(key: string): void {
		this.sessions.delete(key);
		this.drafts.delete(key);
		// A backlog for a session that no longer exists would be sent at the next
		// completion of a session that happens to reuse the key.
		this.queue.clear(key);
	}
}
