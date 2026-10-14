/**
 * Multi-session focus: switching, minting, closing, and recovering.
 *
 * The client keeps a {@link SessionStore} per session and shows exactly one of
 * them. Everything that makes that legal lives here:
 *
 *   - **the switch procedure** — park the outgoing draft, move focus, recover
 *     through owner snapshots, rebuild the transcript, and restore the draft.
 *   - **hydration** — stored history for daemons without snapshot support.
 *     Historical actions remain terminal or outcome-unknown, never live.
 *   - **resync** — replace the focused projection from bounded owner reads
 *     after reconnect, overflow, or selection. Replacement clears native
 *     scrollback: old-branch rows must not survive below the recovered branch.
 *     Session-instance changes fence cached plan/process state even when a
 *     replacement owner uses the same branch and revision identifiers.
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
	SessionsSnapshotResult,
} from "../../protocol/types.ts";
import { newSessionKey } from "../../session-key.ts";
import type { AppStore } from "../../store/app-store.ts";
import type { SessionStore } from "../../store/session-store.ts";
import type { NoticeLevel } from "../../store/transcript-model.ts";
import type { EventController } from "./event-controller.ts";

/** How many stored messages a cold session is hydrated with. */
export const HYDRATE_LIMIT = 100;

/** Owner/event races get at most three read-only attempts per recovery. */
export const SNAPSHOT_RETRY_LIMIT = 3;

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
	onSnapshot?: (result: Extract<SessionsSnapshotResult, { status: "ok" }>, branchChanged: boolean) => void;
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
	readonly #onSnapshot: SessionControllerOptions["onSnapshot"];
	#selectionGeneration = 0;
	#recoveryGeneration = 0;
	#recoveryInFlight: { key: string; selection: number; promise: Promise<void> } | undefined;

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
		this.#onSnapshot = options.onSnapshot;
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
		if (this.#methods.supports(METHOD.sessionsSnapshot)) {
			await this.resync();
		} else {
			await this.#hydrateIfCold(session);
		}
		await this.hydrateRouting(session);
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
			if (this.#methods.supports(METHOD.sessionsSnapshot)) await this.resync();
			if (this.#store.focusedKey !== target) return;
			this.#store.focused.markRead();
			this.#refreshStatus?.();
			return;
		}

		this.#store.setDraft(previousKey, this.#editor.getExpandedText());
		const session = this.#store.setFocused(target);
		const selection = ++this.#selectionGeneration;
		if (this.#methods.supports(METHOD.sessionsSnapshot)) {
			await this.resync();
		} else {
			await this.#hydrateIfCold(session);
		}
		await this.hydrateRouting(session);
		if (selection !== this.#selectionGeneration || this.#store.focusedKey !== target) return;
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
		if (this.#methods.supports(METHOD.sessionsSnapshot)) {
			if (key !== this.#store.focusedKey) return;
			++this.#selectionGeneration;
			await this.resync();
			return;
		}
		const selection = this.#selectionGeneration;
		const result = await this.#methods.chatHistory({
			sessionKey: key,
			cwd: this.#cwd,
			limit: HYDRATE_LIMIT,
			includeFullText: true,
		});
		if (selection !== this.#selectionGeneration || key !== this.#store.focusedKey) return;
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
	 * Compose only owner truth. Failed reads never mean idle or empty approvals.
	 * There is no snapshot text cursor: recovered runs refresh instead of
	 * appending deltas whose relationship to answer-so-far is unknowable.
	 */
	resync(): Promise<void> {
		const session = this.#store.focused;
		const selection = this.#selectionGeneration;
		const current = this.#recoveryInFlight;
		if (current?.key === session.key && current.selection === selection) return current.promise;
		const promise = this.#recover(session, selection).finally(() => {
			if (this.#recoveryInFlight?.promise === promise) this.#recoveryInFlight = undefined;
		});
		this.#recoveryInFlight = { key: session.key, selection, promise };
		return promise;
	}

	async #recover(session: SessionStore, selection: number): Promise<void> {
		if (!this.#methods.supports(METHOD.sessionsSnapshot)) return;
		const generation = ++this.#recoveryGeneration;
		for (let attempt = 0; attempt < SNAPSHOT_RETRY_LIMIT; attempt++) {
			const eventVersion = session.recoveryEventVersion;
			let result: SessionsSnapshotResult;
			try {
				result = await this.#methods.sessionsSnapshot({
					sessionKey: session.key,
					cwd: this.#cwd,
					limit: HYDRATE_LIMIT,
					...(attempt === 0 && session.snapshotIdentity
						? { expectedIdentity: session.snapshotIdentity }
						: {}),
				});
			} catch (error) {
				if (generation !== this.#recoveryGeneration || selection !== this.#selectionGeneration) return;
				if (error instanceof ControlPlaneError && ["FORBIDDEN", "UNAUTHORIZED"].includes(error.code)) {
					this.#replaceApprovals(session.key, []);
				}
				this.#notice(`could not recover ${session.key}: ${describeError(error)}`, "warning");
				return;
			}
			if (
				generation !== this.#recoveryGeneration ||
				selection !== this.#selectionGeneration ||
				this.#store.focusedKey !== session.key ||
				result.sessionKey !== session.key ||
				result.identity.sessionKey !== session.key
			) return;
			if (result.status === "retry" || eventVersion !== session.recoveryEventVersion) continue;
			const snapshot = result.snapshot;
			if (
				result.identity.runId &&
				session.snapshotIdentity?.sessionId === result.identity.sessionId &&
				session.snapshotIdentity?.branchId === result.identity.branchId &&
				session.snapshotIdentity?.runId === result.identity.runId &&
				session.snapshotIdentity?.attempt === result.identity.attempt &&
				session.isRunTerminal(result.identity.runId) &&
				!snapshot.terminal
			) continue;
			const previousBusy = session.busy;
			const previousRunId = session.activeRunId;
			const branchChanged = session.snapshotIdentity?.sessionId !== result.identity.sessionId ||
				session.snapshotIdentity?.revision !== result.identity.revision ||
				session.snapshotIdentity?.branchId !== result.identity.branchId;
			if (branchChanged) {
				session.planMode = undefined;
				session.planPath = undefined;
				session.planWrites += 1;
				session.ownedProcessStates = [];
			}
			session.resetTranscript();
			if (snapshot.phase === "unknown") {
				session.busy = previousBusy;
				session.activeRunId = previousRunId;
				session.addNotice("run state unknown", "warning");
			}
			session.snapshotIdentity = result.identity;
			session.snapshotRunId = result.identity.runId ?? undefined;
			const runId = result.identity.runId;
			synthesizeHistory(
				session,
				snapshot.messages.filter((message) =>
					!(message.role === "assistant" && runId && message.runId === runId),
				),
			);
			synthesizeHistory(session, snapshot.actions);
			for (const action of snapshot.actions) {
				const block = action.toolCallId ? session.byActionId.get(action.toolCallId) : undefined;
				if (block && action.phase === "started" && snapshot.phase === "running") block.historical = false;
			}
			if (snapshot.todos.status === "ok") {
				session.upsertTool(
					{ id: "snapshot:todos", kind: "tool", title: "todo", detail: { name: "todo", details: { todos: snapshot.todos.items } } },
					"completed",
					{ historical: true },
				);
			}
			if (snapshot.plan.status === "ok") {
				const mode = snapshot.plan.value?.mode;
				if (mode === "code" || mode === "plan") session.setPlan(mode, null);
			}
			if (snapshot.processes.status === "ok") {
				session.ownedProcessStates = snapshot.processes.items;
				for (const process of snapshot.processes.items) {
					if (typeof process.identity !== "string") continue;
					const active =
						(process.classification === "queued" || process.classification === "accepted") &&
						(process.status === "queued" || process.status === "running" || process.status === "killing");
					const terminal =
						process.status === "completed" || process.status === "error" || process.status === "killed" ||
						process.classification === "rejected" || process.classification === "expired" || process.classification === "canceled";
					session.upsertTool(
						{
							id: `snapshot:process:${process.identity}`,
							kind: "command",
							title: `process ${process.identity}`,
							detail: { name: "process", details: process },
						},
						terminal ? "completed" : "started",
						{
							historical: !active,
							ok: terminal ? process.status === "completed" : undefined,
							cancelled: process.status === "killed" || process.classification === "canceled",
						},
					);
				}
			}
			for (const [domain, projection] of Object.entries({
				approvals: snapshot.approvals,
				children: snapshot.children,
				processes: snapshot.processes,
				todos: snapshot.todos,
				plan: snapshot.plan,
			})) {
				if (projection.status !== "ok") session.addNotice(`${domain} state ${projection.status}`, "warning");
				if (projection.truncated) session.addNotice(`${domain} snapshot truncated`, "warning");
			}
			for (const [part, truncated] of Object.entries({
				messages: snapshot.messagesTruncated,
				actions: snapshot.actionsTruncated,
				answer: snapshot.answer.truncated,
			})) {
				if (truncated) session.addNotice(`${part} snapshot truncated`, "warning");
			}
			if (runId && snapshot.answer.text) {
				const block = session.appendDelta(runId, Number.NaN, snapshot.answer.text).block;
				if (snapshot.phase === "unknown") block.status = "done";
			}
			if (runId && snapshot.phase !== "unknown") {
				session.activeRunId = runId;
				session.busy = !snapshot.terminal;
				if (snapshot.terminal) {
					session.finalizeRun(runId, {
						ok: snapshot.phase !== "failed",
						interrupted: snapshot.phase === "cancelled",
					});
				}
			}
			if (snapshot.approvals.status === "ok") this.#replaceApprovals(session.key, snapshot.approvals.items);
			else this.#replaceApprovals(session.key, []);
			this.#hydrated.add(session.key);
			this.#onSnapshot?.(result, branchChanged);
			this.#events.rebuildFocused();
			this.#tui.requestRender(true, { clearScrollback: true });
			this.#refreshStatus?.();
			void this.seedContext(session);
			return;
		}
		this.#notice(`recovery for ${session.key} raced with live state; refresh again`, "warning");
	}

	#replaceApprovals(key: string, items: readonly ApprovalRequestedEvent[]): void {
		const pendingIds = new Set(items.map((item) => item.approvalId));
		for (const [id, pending] of this.#store.approvals) {
			if (pending.event.sessionKey === key && !pendingIds.has(id)) this.#events.resolveApproval(id, "unavailable");
		}
		for (const item of items) {
			if (item.sessionKey !== key) continue;
			this.#store.addApproval(item);
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
		return newSessionKey();
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
					runId: typeof message.runId === "string" ? message.runId : undefined,
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


/** `sessions.list` entries name their key under one of three spellings. */
export function sessionKeyOf(summary: SessionSummary | undefined): string | undefined {
	if (!summary) return undefined;
	for (const field of ["sessionKey", "session_key", "key"]) {
		const value = (summary as Record<string, unknown>)[field];
		if (typeof value === "string" && value.length > 0) return value;
	}
	return undefined;
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
