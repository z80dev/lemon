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
 * What happens to a prompt submitted while a run is in flight. P5 only stores
 * the setting; P4 gives `queue`/`steer`/`interrupt` their behaviour.
 */
export type SubmissionMode = "queue" | "steer" | "interrupt";

export interface PendingApproval {
	event: ApprovalRequestedEvent;
	block?: ApprovalBlock;
}

export class AppStore {
	readonly events = new Emitter<AppStoreEventMap>();
	readonly sessions = new Map<string, SessionStore>();
	readonly approvals = new Map<string, PendingApproval>();

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
}
