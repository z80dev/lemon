/**
 * Per-session transcript state.
 *
 * Plain and mutable by design (the omp pattern): controllers are the sole
 * writers, components are dumb render surfaces. Everything a session needs to
 * be rebuilt into components after a switch or a reconnect lives here.
 *
 * The one rule worth stating twice: **the accumulated delta buffer is the
 * source of truth for a run's final text**. `agent completed.answer` is
 * truncated to 500 bytes server-side, so it is only ever a fallback for runs
 * that produced no deltas at all.
 */

import type { AgentAction, RunUsage } from "../protocol/types.ts";
import {
	type ApprovalBlock,
	type AssistantBlock,
	type Block,
	type NoticeBlock,
	type NoticeLevel,
	nextBlockId,
	type ToolBlock,
	type ToolPhase,
	toolTitle,
} from "./transcript-model.ts";

export interface DeltaResult {
	/** False when the delta was a replay (seq <= last seen) and was dropped. */
	accepted: boolean;
	/** True when an accepted delta landed on a block that had already finalized. */
	amended: boolean;
	block: AssistantBlock;
}

/**
 * Where a session's model came from, worst authority first.
 *
 *   `detail`  what `session.detail` resolved the session to — a prediction about
 *             the next run, and the only source that ever loses;
 *   `local`   what the user just pinned with `/model`;
 *   `run`     what a run actually started on, which is the only observed fact of
 *             the three and therefore overrides a local pin that the daemon
 *             evidently did not honour.
 */
export type ModelSource = "detail" | "local" | "run";

/** What a `session.detail` fetch or an `agent started` event can teach a session. */
export interface ModelUpdate {
	model?: string | null;
	provider?: string | null;
	contextWindow?: number | null;
	thinkingLevel?: string | null;
}

export interface FinalizeOptions {
	ok?: boolean | null;
	/** Server-truncated; loses to the delta buffer whenever the buffer has text. */
	answer?: string | null;
	/** Renders an `*[interrupted]*` marker on the block. */
	interrupted?: boolean;
}

export class SessionStore {
	readonly key: string;
	readonly blocks: Block[] = [];
	/** Tool blocks by `action.id`, for phase upserts. */
	readonly byActionId = new Map<string, ToolBlock>();

	activeRunId: string | undefined;
	busy = false;
	/** Whether this session is the one on screen. Owned by {@link AppStore}. */
	focused = false;
	/** Blocks appended while this session was not focused. */
	unread = 0;
	/**
	 * When the last run ended, or 0 while none ever has. Read by the submission
	 * modes: a live correction that arrives moments after a run finished lost a race
	 * rather than being nonsense, and says so instead of failing silently.
	 */
	lastRunEndedAtMs = 0;
	/** Last engine reported by `agent started`, for the status line. */
	engine: string | undefined;
	/** Model this session runs on, as last set through `/model` or reported. */
	model: string | undefined;
	/** Where {@link model} came from. See {@link setModel} for what that buys. */
	modelSource: ModelSource | undefined;
	/** Provider of {@link model}, when the daemon named one. */
	provider: string | undefined;
	/**
	 * Context window of {@link model} as the daemon reported it. Preferred over
	 * the `models.list` cache, which cannot know about a model the daemon has but
	 * the catalog does not.
	 */
	contextWindow: number | undefined;
	/** Token counts from this session's most recent completed run. */
	usage: RunUsage | undefined;
	/** Reasoning effort, as last set through `/think`. */
	thinkingLevel: string | undefined;
	/** Tool-policy profile, as last set through `/toolpolicy`. */
	toolPolicy: string | undefined;

	/** runId -> accumulated delta text. */
	readonly #buffers = new Map<string, string>();
	/** runId -> highest delta seq accepted. */
	readonly #deltaSeqs = new Map<string, number>();
	/** runId -> the assistant block that run streams into. */
	readonly #assistantByRun = new Map<string, AssistantBlock>();
	/** Runs whose buffer holds the server's truncated answer, not streamed text. */
	readonly #answerOnly = new Set<string>();

	constructor(key: string) {
		this.key = key;
	}

	// -- reads ---------------------------------------------------------------

	/** Accumulated delta text for a run (empty string when nothing streamed). */
	bufferFor(runId: string): string {
		return this.#buffers.get(runId) ?? "";
	}

	assistantFor(runId: string): AssistantBlock | undefined {
		return this.#assistantByRun.get(runId);
	}

	get lastBlock(): Block | undefined {
		return this.blocks[this.blocks.length - 1];
	}

	// -- routing -------------------------------------------------------------

	/**
	 * Record what model this session is on, resolving against what we already knew.
	 *
	 * A `detail` fetch is a prediction and yields to anything better, so switching
	 * back to a session cannot undo a `/model` the user set moments ago or
	 * relabel a run that is already going. `local` and `run` always apply, in the
	 * order they happen: the user pinning a model is the newest intent, and a run
	 * reporting one is the newest fact.
	 *
	 * Returns whether anything visible changed, so callers can skip a repaint.
	 */
	setModel(update: ModelUpdate, source: ModelSource): boolean {
		const model = blankToUndefined(update.model);
		if (source === "detail" && this.modelSource && this.modelSource !== "detail") return false;
		if (!model && source !== "local") return false;

		const previous = {
			model: this.model,
			provider: this.provider,
			contextWindow: this.contextWindow,
			thinkingLevel: this.thinkingLevel,
		};
		// Provider and window describe a specific model, so a *different* model
		// clears them rather than leaving the old model's facts standing beside a new
		// id. The same model keeps them: `agent completed` names the model without
		// re-stating either, and must not undo what `started` taught us.
		const changed = model !== this.model;
		const provider = blankToUndefined(update.provider);
		const contextWindow = positive(update.contextWindow);
		const thinking = blankToUndefined(update.thinkingLevel);

		this.model = model;
		this.modelSource = source;
		if (changed || provider !== undefined) this.provider = provider;
		if (changed || contextWindow !== undefined) this.contextWindow = contextWindow;
		if (thinking !== undefined) this.thinkingLevel = thinking;

		return (
			previous.model !== this.model ||
			previous.provider !== this.provider ||
			previous.contextWindow !== this.contextWindow ||
			previous.thinkingLevel !== this.thinkingLevel
		);
	}

	/** Take token counts from a completed run. A run that reported none clears nothing. */
	applyUsage(usage: RunUsage | null | undefined): void {
		if (!usage) return;
		this.usage = usage;
	}

	/**
	 * Tokens for the context gauge: how big the conversation was on the last turn.
	 *
	 * Only a real measurement of the input side counts. `totalTokens` is deliberately
	 * not a fallback — engines report it cumulatively across every turn of a run (a
	 * live run showed 86k total against a 21k context), so putting it in the gauge
	 * would draw a bar that only ever climbs and never matches the conversation.
	 * Undefined here makes the status bar fall back to its honest `use N` label.
	 */
	get contextTokens(): number | undefined {
		const usage = this.usage;
		if (!usage) return undefined;
		const context = positive(usage.contextTokens);
		if (context !== undefined) return context;
		const input = positive(usage.inputTokens);
		if (input === undefined) return undefined;
		return input + (positive(usage.cacheReadTokens) ?? 0) + (positive(usage.cacheWriteTokens) ?? 0);
	}

	// -- writes --------------------------------------------------------------

	addUser(text: string, at = Date.now()): Block {
		return this.#push({ id: nextBlockId("user"), kind: "user", at, text });
	}

	addNotice(text: string, level: NoticeLevel = "info", at = Date.now()): NoticeBlock {
		return this.#push({
			id: nextBlockId("notice"),
			kind: "notice",
			at,
			level,
			text,
		}) as NoticeBlock;
	}

	addApprovalBlock(approvalId: string, tool: string | undefined, at = Date.now()): ApprovalBlock {
		return this.#push({
			id: nextBlockId("approval"),
			kind: "approval",
			at,
			approvalId,
			tool,
			status: "pending",
		}) as ApprovalBlock;
	}

	/**
	 * The assistant block a run streams into, created on first sight. `agent
	 * started` and the first `chat delta` race in practice, so both call this.
	 */
	ensureAssistant(runId: string, at = Date.now()): AssistantBlock {
		const existing = this.#assistantByRun.get(runId);
		if (existing) return existing;
		const block: AssistantBlock = {
			id: nextBlockId("assistant"),
			kind: "assistant",
			at,
			runId,
			text: "",
			status: "streaming",
		};
		this.#assistantByRun.set(runId, block);
		this.#push(block);
		return block;
	}

	/**
	 * Accumulate one streaming delta. Deltas are per-run monotonic but the
	 * transport can redeliver them across a reconnect, so anything at or below
	 * the highest seq seen for the run is dropped.
	 *
	 * A *higher* seq arriving after the run finalized is not a replay — the
	 * transport reordered `completed` ahead of the tail of the stream — so it
	 * amends the sealed block rather than being thrown away. The result reports
	 * that case through {@link DeltaResult.amended} so the controller can repaint
	 * the finalized component (bumping its block version) instead of restarting
	 * a reveal on a block that is already history.
	 */
	appendDelta(runId: string, seq: number, text: string): DeltaResult {
		const block = this.ensureAssistant(runId);
		if (Number.isFinite(seq)) {
			const previous = this.#deltaSeqs.get(runId);
			if (previous !== undefined && seq <= previous) {
				return { accepted: false, amended: false, block };
			}
			this.#deltaSeqs.set(runId, seq);
		}
		const amended = block.status !== "streaming";
		// A finalized block whose text came from the truncated `answer` fallback
		// has no real stream behind it; the first genuine delta supersedes that
		// summary instead of being appended to it.
		if (amended && this.#answerOnly.has(runId)) {
			this.#answerOnly.delete(runId);
			this.#buffers.set(runId, "");
		}
		const buffer = (this.#buffers.get(runId) ?? "") + (text ?? "");
		this.#buffers.set(runId, buffer);
		block.text = buffer;
		return { accepted: true, amended, block };
	}

	/**
	 * Insert or update the tool block for `action.id`. Actions without an id are
	 * given a synthetic one so repeated phases of the same untitled action still
	 * collapse onto one block rather than stacking.
	 */
	upsertTool(
		action: AgentAction | undefined,
		phase: ToolPhase,
		options: { runId?: string | null; ok?: boolean | null; message?: string | null } = {},
	): ToolBlock {
		const actionId = action?.id?.trim() || `${options.runId ?? "run"}:${toolTitle(action)}`;
		const existing = this.byActionId.get(actionId);
		const detail = (action?.detail ?? undefined) as Record<string, unknown> | undefined;
		if (existing) {
			// A tool action's phase only ever advances. The transport can redeliver a
			// `started`/`updated` frame after the result landed (a reconnect replay,
			// an engine that re-announces a call), and applying it would regress a
			// finalized ✓/✗ card back to running: the transcript would reopen its
			// commit seam, and any completed row already written to native scrollback
			// would be stranded there as stale bytes. The whole update is dropped,
			// not just the phase — a `started` frame carries the pre-result detail,
			// so merging it would erase the result from an already-sealed card.
			if (existing.phase === "completed" && phase !== "completed") return existing;
			existing.phase = phase;
			existing.title = toolTitle(action) || existing.title;
			if (detail !== undefined) existing.detail = detail;
			if (action?.kind) existing.toolKind = action.kind;
			if (options.ok !== undefined && options.ok !== null) existing.ok = options.ok;
			if (options.message !== undefined && options.message !== null) {
				existing.message = options.message;
			}
			return existing;
		}
		const block: ToolBlock = {
			id: nextBlockId("tool"),
			kind: "tool",
			at: Date.now(),
			runId: options.runId ?? undefined,
			actionId,
			toolKind: action?.kind ?? "tool",
			title: toolTitle(action),
			detail,
			phase,
			ok: options.ok ?? undefined,
			message: options.message ?? undefined,
		};
		this.byActionId.set(actionId, block);
		this.#push(block);
		return block;
	}

	/**
	 * End a run. Returns the assistant block, creating one when `completed`
	 * outran `started` and the whole stream — the answer it carries (truncated
	 * or not) is all the client will ever get for that run, so it must not be
	 * dropped on the floor. A run that produced nothing at all (no block, empty
	 * answer) still returns undefined: there is nothing to show, and the caller
	 * reports the failure its own way.
	 */
	finalizeRun(runId: string, options: FinalizeOptions = {}): AssistantBlock | undefined {
		const answer = options.answer ?? "";
		const block =
			this.#assistantByRun.get(runId) ?? (answer ? this.ensureAssistant(runId) : undefined);
		if (this.activeRunId === runId) {
			this.activeRunId = undefined;
			this.busy = false;
			this.lastRunEndedAtMs = Date.now();
		}
		if (!block) return undefined;
		if (block.status !== "streaming") return block;

		const buffered = this.bufferFor(runId);
		// The buffer wins: `answer` is truncated to 500 bytes server-side.
		const text = buffered.length > 0 ? buffered : answer;
		block.text = text;
		this.#buffers.set(runId, text);
		// Remember that this run's text is the server's summary rather than a
		// stream, so a late delta replaces it instead of appending to it.
		if (buffered.length === 0 && answer) this.#answerOnly.add(runId);
		if (options.interrupted) {
			block.status = "aborted";
		} else if (options.ok === false) {
			block.status = "error";
			// Surface the server's message only when it is not already the body.
			block.error = answer && answer !== text ? answer : undefined;
		} else {
			block.status = "done";
		}
		return block;
	}

	/** Mark a still-streaming run as user-interrupted, keeping partial text. */
	markInterrupted(runId: string): AssistantBlock | undefined {
		return this.finalizeRun(runId, { interrupted: true });
	}

	markRead(): void {
		this.unread = 0;
	}

	// -- internals -----------------------------------------------------------

	#push<T extends Block>(block: T): T {
		this.blocks.push(block);
		// The user's own message is never "unread" — they just typed it.
		if (!this.focused && block.kind !== "user") this.unread += 1;
		return block;
	}
}

/** The wire says `null` for "not known"; the store says `undefined`. */
function blankToUndefined(value: string | null | undefined): string | undefined {
	if (typeof value !== "string") return undefined;
	const trimmed = value.trim();
	return trimmed.length > 0 ? trimmed : undefined;
}

function positive(value: number | null | undefined): number | undefined {
	return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : undefined;
}
