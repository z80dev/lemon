/**
 * Multi-session focus: switching, minting, closing, and recovering.
 *
 * The client keeps a {@link SessionStore} per session and shows exactly one of
 * them. Everything that makes that legal lives here:
 *
 *   - **the switch procedure** — park the outgoing draft, move focus, hydrate a
 *     cold session from `chat.history`, rebuild the transcript components from
 *     the block models, clear native scrollback, restore the incoming draft.
 *     A session switch is *the only* sanctioned `clearScrollback` gesture
 *     besides `/clear`: the terminal is holding rows for a transcript we are
 *     about to stop showing, and rows the client can no longer reason about are
 *     worse than no rows at all.
 *   - **hydration** — server-side history synthesized into transcript blocks.
 *     Every synthesized run is finalized, so a rebuilt session never reports a
 *     live region that no stream will ever close.
 *   - **resync** — after a reconnect, re-read what moved while the socket was
 *     down without duplicating anything already on screen.
 *
 * The controller writes stores and asks {@link EventController} to mirror them;
 * it never builds a component itself. That keeps the "one writer of the
 * transcript tree" rule intact even though two controllers now cause writes.
 */

import type { TUI } from "@oh-my-pi/pi-tui/tui";
import {
	ControlPlaneError,
	NotConnectedError,
	RequestTimeoutError,
} from "../../protocol/errors.ts";
import type { ControlPlaneMethods } from "../../protocol/methods.ts";
import { METHOD } from "../../protocol/methods.ts";
import type {
	ApprovalRequestedEvent,
	ChatHistoryMessage,
	SessionSummary,
} from "../../protocol/types.ts";
import { newSessionKey } from "../../session-key.ts";
import type { AppStore } from "../../store/app-store.ts";
import type { SessionStore } from "../../store/session-store.ts";
import type { NoticeLevel } from "../../store/transcript-model.ts";
import type { EventController } from "./event-controller.ts";

/** How many stored messages a cold session is hydrated with. */
export const HYDRATE_LIMIT = 100;

/** How far back resync looks for messages that landed while we were away. */
export const RESYNC_TAIL_LIMIT = 20;

/** The slice of the editor a switch needs. */
export interface DraftEditor {
	getExpandedText(): string;
	setText(text: string): void;
}

export interface SessionControllerOptions {
	store: AppStore;
	methods: ControlPlaneMethods;
	events: EventController;
	tui: TUI;
	editor: DraftEditor;
	cwd?: string;
	/** Sends a prompt as the user (used by "new session with a first prompt"). */
	sendPrompt?: (text: string) => void | Promise<void>;
	refreshStatus?: () => void;
	/** Presents a yes/no overlay. Without one, closing needs `confirmed: true`. */
	confirm?: (spec: ConfirmSpec) => void;
}

export interface ConfirmSpec {
	title: string;
	/** The affirmative option's label. */
	confirmLabel: string;
	onConfirm: () => void | Promise<void>;
	onCancel?: () => void;
}

export class SessionController {
	readonly #store: AppStore;
	readonly #methods: ControlPlaneMethods;
	readonly #events: EventController;
	readonly #tui: TUI;
	readonly #editor: DraftEditor;
	readonly #cwd: string | undefined;
	readonly #sendPrompt: ((text: string) => void | Promise<void>) | undefined;
	readonly #refreshStatus: (() => void) | undefined;
	readonly #confirm: ((spec: ConfirmSpec) => void) | undefined;

	/** Sessions whose stored history has been pulled (or never needed pulling). */
	readonly #hydrated = new Set<string>();
	/** Sessions whose gauge `sessions.context` already answered for (success or a definite no). */
	readonly #contextSeeded = new Set<string>();

	constructor(options: SessionControllerOptions) {
		this.#store = options.store;
		this.#methods = options.methods;
		this.#events = options.events;
		this.#tui = options.tui;
		this.#editor = options.editor;
		this.#cwd = options.cwd;
		this.#sendPrompt = options.sendPrompt;
		this.#refreshStatus = options.refreshStatus;
		this.#confirm = options.confirm;
	}

	/** Sessions this client has already hydrated (or minted, so never will). */
	get hydratedKeys(): ReadonlySet<string> {
		return this.#hydrated;
	}

	/** Mark a session as needing no hydration (it was minted here). */
	markHydrated(key: string): void {
		this.#hydrated.add(key);
	}

	// -- switching -----------------------------------------------------------

	/** Hydrate an explicit launch key before the initial composer is ready. */
	async initialize(): Promise<void> {
		const session = this.#store.focused;
		await Promise.all([
			this.#hydrateIfCold(session),
			this.hydrateRouting(session),
			this.#resyncActive(),
			this.#resyncApprovals(),
		]);
		this.#events.rebuildFocused();
		this.#refreshStatus?.();
		void this.seedContext(session);
	}

	/**
	 * Focus `key`, hydrating and rebuilding as needed.
	 *
	 * Order matters and is the contract:
	 *   1. park the outgoing draft (before anything can touch the editor);
	 *   2. move focus, which resets the incoming session's unread count;
	 *   3. hydrate if the session is cold — while focused, so hydrated blocks
	 *      are not counted as unread;
	 *   4. rebuild the transcript tree from the block models;
	 *   5. restore the incoming draft;
	 *   6. repaint with cleared scrollback.
	 */
	async switch(key: string): Promise<void> {
		const target = key.trim();
		if (target.length === 0) return;
		const previousKey = this.#store.focusedKey;
		if (target === previousKey) {
			// Still worth the unread reset and a status repaint: the switcher can
			// land here from a row the user picked while events were arriving.
			this.#store.focused.markRead();
			this.#refreshStatus?.();
			return;
		}

		this.#store.setDraft(previousKey, this.#editor.getExpandedText());
		const session = this.#store.setFocused(target);
		await Promise.all([this.#hydrateIfCold(session), this.hydrateRouting(session)]);
		session.markRead();
		this.#events.rebuildFocused();
		this.#editor.setText(this.#store.takeDraft(target));
		this.#tui.requestRender(true, { clearScrollback: true });
		this.#refreshStatus?.();
		void this.seedContext(session);
	}

	/**
	 * Mint a session and switch to it. The daemon has no notion of it until the
	 * first `chat.send`, which is why nothing is called here — a key the user
	 * abandons costs the daemon nothing.
	 */
	async create(key?: string, prompt?: string): Promise<string> {
		const target = (key ?? "").trim() || this.#mintKey();
		// A minted key has no stored history, so hydration would only be a
		// round-trip that returns nothing.
		this.#hydrated.add(target);
		await this.switch(target);
		const first = prompt?.trim();
		if (first) await this.#sendPrompt?.(first);
		return target;
	}

	/** Ask before closing, when a confirm host is mounted. */
	requestClose(key: string): void {
		if (!this.#confirm) {
			void this.close(key, { confirmed: true });
			return;
		}
		this.#confirm({
			title: `close ${key}? its stored history is deleted`,
			confirmLabel: `delete ${key}`,
			onConfirm: () => this.close(key, { confirmed: true }),
		});
	}

	/**
	 * Drop a session locally and, when the daemon supports it, server-side.
	 * Closing the focused session moves focus first: the store recreates any
	 * session that is focused while absent, so deleting it in place would leave
	 * an empty ghost behind under the same key.
	 */
	async close(key: string, options: { confirmed?: boolean } = {}): Promise<void> {
		if (!options.confirmed) {
			this.requestClose(key);
			return;
		}
		if (key === this.#store.focusedKey) {
			await this.switch(this.#nextFocusAfter(key));
		}
		this.#store.forgetSession(key);
		this.#hydrated.delete(key);
		if (this.#methods.supports(METHOD.sessionsDelete)) {
			try {
				await this.#methods.sessionsDelete({ sessionKey: key });
				this.#notice(`closed ${key}`, "warning");
			} catch (error) {
				this.#notice(`closed ${key} locally; daemon: ${describeError(error)}`, "warning");
			}
		} else {
			this.#notice(`closed ${key} locally (daemon does not support ${METHOD.sessionsDelete})`);
		}
		this.#refreshStatus?.();
	}

	/**
	 * Drop only the client copy after `sessions.delete` or `sessions.prune`
	 * returned a verified deletion. This must not call the daemon again: the
	 * lifecycle response is the commit point, and a duplicate destructive call
	 * could turn a successful operation into a misleading error during a race.
	 */
	async forgetDeleted(key: string): Promise<void> {
		if (key === this.#store.focusedKey) await this.switch(this.#nextFocusAfter(key));
		this.#store.forgetSession(key);
		this.#hydrated.delete(key);
		this.#refreshStatus?.();
	}

	/**
	 * Forget a session's transcript without touching the daemon. `/session reset`
	 * pairs this with `sessions.reset` so both sides start empty.
	 */
	resetLocal(key: string = this.#store.focusedKey): void {
		const session = this.#store.sessions.get(key);
		if (!session) return;
		session.resetTranscript();
		// The transcript is gone, so the stored history may legitimately be
		// re-pulled on a later switch.
		this.#hydrated.delete(key);
		if (key !== this.#store.focusedKey) return;
		this.#events.rebuildFocused();
		this.#tui.requestRender(true, { clearScrollback: true });
	}

	/** Replace abandoned history only after the daemon returned its active branch. */
	async reload(key: string): Promise<void> {
		const result = await this.#methods.chatHistory({
			sessionKey: key,
			cwd: this.#cwd,
			limit: HYDRATE_LIMIT,
			includeFullText: true,
		});
		const session = this.#store.session(key);
		session.resetTranscript();
		synthesizeHistory(session, result.messages ?? []);
		this.#hydrated.add(key);
		if (key === this.#store.focusedKey) {
			this.#events.rebuildFocused();
			this.#tui.requestRender(true, { clearScrollback: true });
			this.#refreshStatus?.();
		}
	}

	// -- hydration -----------------------------------------------------------

	/**
	 * Ask the daemon what model this session resolves to, so the status bar names
	 * something true before the first run rather than "no model".
	 *
	 * The answer is a prediction about the next run, which is why it is applied at
	 * the lowest precedence: a `/model` the user just set, or a model a run already
	 * reported, both outrank it. Failures are silent — a missing model label is not
	 * worth a notice, and older daemons have no such keys to give.
	 */
	async hydrateRouting(session: SessionStore): Promise<void> {
		if (!this.#methods.supports(METHOD.sessionDetail)) return;
		try {
			const result = await this.#methods.sessionDetail({ sessionKey: session.key });
			const detail = (result?.session ?? {}) as Record<string, unknown>;
			const previousTitle = session.title;
			if (typeof detail.title === "string" || detail.title === null) {
				session.title = asString(detail.title);
			}
			const changed = session.setModel(
				{
					model: asString(detail.model),
					provider: asString(detail.provider),
					contextWindow: asNumber(detail.contextWindow),
					thinkingLevel: asString(detail.thinkingLevel),
				},
				"detail",
			);
			if (changed || previousTitle !== session.title) this.#refreshStatus?.();
		} catch {
			// Nothing to show and nothing to say: the status bar keeps what it had.
		}
	}

	/**
	 * Give the gauge the daemon's measurement for a session that has durable
	 * history but no run usage yet (a resumed or switched-to session), once.
	 * Every failure is silent: `not_found`/`unavailable` are definite answers and
	 * are not asked again; an offline or timed-out attempt may be retried on the
	 * next focus or resync. Never queued, never polled.
	 */
	async seedContext(session: SessionStore): Promise<void> {
		if (
			this.#contextSeeded.has(session.key) ||
			session.usage ||
			session.contextMeasurement ||
			!this.#methods.supports(METHOD.sessionsContext) ||
			this.#methods.client.state !== "online" ||
			!session.blocks.some((block) => block.kind === "user" || block.kind === "assistant")
		) {
			return;
		}
		this.#contextSeeded.add(session.key);
		try {
			const usage = await this.#methods.sessionsContext({
				sessionKey: session.key,
				cwd: this.#cwd ?? process.cwd(),
			});
			// A run that completed meanwhile reported something newer.
			if (usage.sessionKey !== session.key || session.usage || session.contextMeasurement) return;
			session.applyContextMeasurement(usage.usedTokens, usage.window);
			if (session.key === this.#store.focusedKey) this.#refreshStatus?.();
		} catch (error) {
			if (error instanceof NotConnectedError || error instanceof RequestTimeoutError) {
				this.#contextSeeded.delete(session.key);
			}
		}
	}

	/** Pull stored history for a session that has nothing on screen yet. */
	async #hydrateIfCold(session: SessionStore): Promise<void> {
		if (this.#hydrated.has(session.key)) return;
		if (session.blocks.some((block) => block.kind !== "notice")) {
			// Live events already built a transcript; stored history would double it.
			this.#hydrated.add(session.key);
			return;
		}
		this.#hydrated.add(session.key);
		if (!this.#methods.supports(METHOD.chatHistory)) return;
		try {
			const result = await this.#methods.chatHistory({
				sessionKey: session.key,
				cwd: this.#cwd,
				limit: HYDRATE_LIMIT,
				includeFullText: true,
			});
			const messages = (result?.messages ?? []) as ChatHistoryMessage[];
			if (messages.length > 0) synthesizeHistory(session, messages);
		} catch (error) {
			// A session with no stored history is the common case and answers with
			// an error on some daemons; either way an empty transcript is correct.
			this.#notice(`could not load history for ${session.key}: ${describeError(error)}`, "warning");
		}
	}

	// -- reconnect recovery --------------------------------------------------

	/**
	 * Re-read the world after a reconnect: which sessions are live, whatever
	 * landed in the focused one while the socket was down, and any approval that
	 * is still waiting.
	 *
	 * Everything here is additive and de-duplicated. A resync that replayed
	 * history the transcript already shows would be worse than one that missed a
	 * message: the user cannot tell a duplicate from a repeat.
	 */
	async resync(): Promise<void> {
		await Promise.all([
			this.#resyncActive(),
			this.#resyncTail(),
			this.#resyncApprovals(),
			this.hydrateRouting(this.#store.focused),
		]);
		this.#refreshStatus?.();
		void this.seedContext(this.#store.focused);
	}

	async #resyncActive(): Promise<void> {
		if (!this.#methods.supports(METHOD.sessionsActiveList)) return;
		const result = await this.#methods.sessionsActiveList().catch(() => undefined);
		const active = new Set<string>();
		for (const entry of (result?.sessions ?? []) as SessionSummary[]) {
			const key = sessionKeyOf(entry);
			if (key) active.add(key);
		}
		// Only sessions this client already knows are touched: materializing every
		// server-side session would inflate the session count with transcripts
		// nobody asked for.
		for (const session of this.#store.sessions.values()) {
			const busy = active.has(session.key);
			if (session.busy === busy) continue;
			session.busy = busy;
			if (!busy) session.activeRunId = undefined;
		}
	}

	/**
	 * Append the conversation the daemon has that this transcript does not.
	 *
	 * The floor is the newest block that *came from the daemon*, never simply the
	 * last block: reconnecting writes its own notices ("reconnected") stamped
	 * now, and measuring against one of those would rule out every message that
	 * landed during the outage — the exact messages this exists to recover.
	 *
	 * With no daemon-sourced block at all (a transcript holding nothing but
	 * connection notices) the floor is zero and this becomes an ordinary
	 * hydrate. Either way blocks are only ever appended, so no rebuild and no
	 * scrollback clearing is involved.
	 */
	async #resyncTail(): Promise<void> {
		if (!this.#methods.supports(METHOD.chatHistory)) return;
		const session = this.#store.focused;
		const since = lastDaemonBlockAt(session);
		const cold = since === undefined;
		const result = await this.#methods
			.chatHistory({
				sessionKey: session.key,
				cwd: this.#cwd,
				limit: cold ? HYDRATE_LIMIT : RESYNC_TAIL_LIMIT,
				includeFullText: true,
			})
			.catch(() => undefined);
		const messages = (result?.messages ?? []) as ChatHistoryMessage[];
		// Nothing of the daemon's is on screen, so nothing can be duplicated and
		// even messages the daemon stored without a timestamp are safe to take.
		const missed = cold
			? messages
			: messages.filter((message) => {
					const at = message.timestampMs;
					// A message without a timestamp cannot be placed against what is on
					// screen, so it is left alone rather than guessed at.
					return typeof at === "number" && at > since;
				});
		if (missed.length > 0) this.#hydrated.add(session.key);
		if (missed.length === 0) return;
		synthesizeHistory(session, missed);
		// The notice is not only for the user: appending a block is what makes the
		// event controller walk the tail of the block list, so this is also what
		// puts components under the messages just synthesized. Recovering silently
		// would leave them in the model and off the screen.
		this.#events.notice(`recovered ${missed.length} message(s) missed while offline`, "warning");
	}

	async #resyncApprovals(): Promise<void> {
		if (!this.#methods.supports(METHOD.approvalsGet)) return;
		const result = await this.#methods.approvalsGet().catch(() => undefined);
		for (const pending of pendingApprovalsFrom(result)) {
			if (this.#store.approvals.has(pending.approvalId)) continue;
			this.#store.addApproval(pending);
		}
	}

	// -- internals -----------------------------------------------------------

	/** The session focus falls back to when the focused one is closed. */
	#nextFocusAfter(key: string): string {
		let fallback: SessionStore | undefined;
		for (const session of this.#store.sessions.values()) {
			if (session.key === key) continue;
			if (!fallback || (session.lastBlock?.at ?? 0) > (fallback.lastBlock?.at ?? 0)) {
				fallback = session;
			}
		}
		return fallback?.key ?? this.#mintKey();
	}

	#mintKey(): string {
		return newSessionKey(this.#cwd);
	}

	#notice(text: string, level: NoticeLevel = "info"): void {
		this.#events.notice(text, level);
	}
}

/**
 * Turn stored history into transcript blocks, best effort.
 *
 * Every assistant message becomes a finalized block under a synthetic run id
 * (`history:<message id>`), which is what keeps a rebuilt transcript out of the
 * streaming state: a block that reports itself live pins the native-scrollback
 * commit seam open for the rest of the session. Tool calls and results share
 * their native call id. A saved call without a result remains outcome-unknown,
 * not a fabricated success or a live execution.
 */
export function synthesizeHistory(session: SessionStore, messages: ChatHistoryMessage[]): void {
	const calls = new Map<string, ChatHistoryMessage>();
	for (const message of messages) {
		if (message.role === "tool_use" && message.toolCallId) {
			calls.set(message.toolCallId, message);
		}
	}
	for (const message of messages) {
		const at = message.timestampMs ?? Date.now();
		const content = message.content ?? "";
		const role = (message.role ?? "").toLowerCase();
		if (role === "user") {
			// Only a recorded timestamp is a send time; hydration time is not.
			session.addUser(content, at, message.timestampMs ? { sentAt: message.timestampMs } : {});
			continue;
		}
		if (role === "assistant" || role === "") {
			const runId = `history:${message.id}`;
			session.ensureAssistant(runId, at);
			// Seq is NaN on purpose: stored text is not part of any run's delta
			// sequence, and a finite seq here would make a later live delta for the
			// same (synthetic) run look like a replay.
			session.appendDelta(runId, Number.NaN, content);
			session.finalizeRun(runId, { ok: true });
			continue;
		}
		if (role === "tool" || role === "tool_use" || role === "tool_result") {
			const actionId = message.toolCallId || `history:${message.id}`;
			const call = calls.get(actionId);
			const previous = session.byActionId.get(actionId);
			const completed = role === "tool_result" || role === "tool" || message.phase === "completed";
			const details = message.details ?? call?.details ?? previous?.detail?.details;
			const durationMs = message.durationMs;
			session.upsertTool(
				{
					id: actionId,
					kind: "tool",
					title: message.title ?? call?.title ?? previous?.title ?? historyToolTitle(message),
					detail: {
						...previous?.detail,
						name:
							message.toolName ??
							call?.toolName ??
							previous?.detail?.name ??
							historyToolTitle(message),
						args: message.arguments ?? call?.arguments ?? previous?.detail?.args,
						details,
						...(completed ? { result: content } : {}),
					},
				},
				completed ? "completed" : "started",
				{
					at: message.timestampMs ?? 0,
					historical: true,
					ok: message.ok,
					cancelled:
						completed &&
						(message.cancelled === true ||
							message.details?.cancelled === true ||
							message.details?.error_type === "aborted"),
					durationMs:
						completed &&
						typeof durationMs === "number" &&
						Number.isFinite(durationMs) &&
						durationMs >= 0
							? durationMs
							: undefined,
				},
			);
			continue;
		}
		session.addNotice(`${role}: ${content}`, "info", at);
	}
}

/** The best name a stored tool record offers. */
function historyToolTitle(message: ChatHistoryMessage): string {
	for (const field of ["name", "tool", "toolName", "title"]) {
		const value = message[field];
		if (typeof value === "string" && value.trim().length > 0) return value;
	}
	return "tool";
}

/**
 * When the daemon last said something in this transcript.
 *
 * Notices and approval records are the client talking to itself; only the
 * conversation blocks can be compared against what the daemon has stored.
 * Undefined means nothing on screen came from the daemon at all.
 */
export function lastDaemonBlockAt(session: SessionStore): number | undefined {
	for (let index = session.blocks.length - 1; index >= 0; index--) {
		const block = session.blocks[index];
		if (
			block.kind === "user" ||
			block.kind === "assistant" ||
			block.kind === "tool" ||
			block.kind === "reasoning"
		) {
			return block.at;
		}
	}
	return undefined;
}

/** `sessions.list` entries name their key under one of three spellings. */
export function sessionKeyOf(summary: SessionSummary | undefined): string | undefined {
	if (!summary) return undefined;
	for (const field of ["sessionKey", "session_key", "key"]) {
		const value = (summary as Record<string, unknown>)[field];
		if (typeof value === "string" && value.length > 0) return value;
	}
	return undefined;
}

/**
 * Pull pending approvals out of an `exec.approvals.get` payload. The method
 * answers with either a bare list or `{approvals: [...]}`, and entries missing
 * an id are not actionable, so they are skipped rather than surfaced.
 */
export function pendingApprovalsFrom(result: unknown): ApprovalRequestedEvent[] {
	const list = Array.isArray(result)
		? result
		: Array.isArray((result as { approvals?: unknown })?.approvals)
			? ((result as { approvals: unknown[] }).approvals as unknown[])
			: [];
	const approvals: ApprovalRequestedEvent[] = [];
	for (const entry of list) {
		if (typeof entry !== "object" || entry === null) continue;
		const record = entry as Record<string, unknown>;
		const approvalId = record.approvalId ?? record.approval_id ?? record.id;
		if (typeof approvalId !== "string" || approvalId.length === 0) continue;
		approvals.push({ ...(record as object), approvalId } as ApprovalRequestedEvent);
	}
	return approvals;
}

function describeError(error: unknown): string {
	if (error instanceof ControlPlaneError) return error.code;
	if (error instanceof NotConnectedError || error instanceof RequestTimeoutError) return error.code;
	return "UNAVAILABLE";
}

function asString(value: unknown): string | undefined {
	return typeof value === "string" ? value : undefined;
}

function asNumber(value: unknown): number | undefined {
	return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}
