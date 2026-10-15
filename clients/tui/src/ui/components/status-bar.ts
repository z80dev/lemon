/**
 * The status line: one row, whatever the terminal is wide.
 *
 * Progressive disclosure by priority rather than by fixed breakpoints. Two
 * segments are pinned — the model and the context gauge — because they are the
 * two facts that change what the user types next; everything else drops from
 * the lowest priority up until the row fits. A pinned segment is never
 * truncated to make room for an optional one, so an 60-column terminal shows a
 * short true line instead of a long crushed one.
 *
 * The component is dumb: it renders whatever {@link StatusBarData} the host
 * hands it. Git is the one exception — the branch is polled here because
 * nothing else wants it, and the poll is stopped by `dispose()`.
 *
 * A TSP terminal gets no status strip: like omp, the prompt composer carries
 * these facts ({@link StatusBar.describeComposerFacts}) and the bar describes
 * itself hidden.
 */

import { node, span } from "@oh-my-pi/pi-tui/native/describe";
import type { NativeNode, NativeUiEvent, TspSpan } from "@oh-my-pi/pi-tui/native/node";
import { styledSpans } from "@oh-my-pi/pi-tui/native/spans";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth, visibleWidth } from "@oh-my-pi/pi-tui/utils";
import type { ConnectionState } from "../../protocol/types.ts";
import type { SubmissionMode } from "../../store/app-store.ts";
import { type ColorSlot, getTheme } from "../theme/theme.ts";

export interface StatusBarData {
	sessionKey: string;
	model?: string;
	/** Tokens against the model's window; both are needed for the gauge. */
	contextTokens?: number;
	contextWindow?: number;
	/**
	 * What {@link contextTokens} actually counts. `context` is this session's last
	 * turn and earns a gauge; `aggregate` is `usage.status`, which is every session's
	 * tokens for the whole day and is therefore not a context measurement at all.
	 */
	contextSource?: ContextSource;
	/** Last completed run, not the conversation's context size. */
	runTokens?: number;
	runCostUsd?: number;
	/** Client-side follow-ups for the focused session. */
	pendingPrompts?: number;
	branch?: string | null;
	sessionCount: number;
	busy: boolean;
	/** Sessions with a run in flight, including ones off screen. */
	busySessions?: number;
	unread: number;
	approvals: number;
	connection: ConnectionState;
	mode: SubmissionMode;
	thinking?: string;
	engine?: string;
	queued: number;
	/** The focused session's daemon plan mode; only `plan` earns a segment. */
	planMode?: "plan" | "code";
	/** omp delegate processes starting or working now, across every session. */
	ompBusy?: number;
}

export type ContextSource = "context" | "aggregate";

type SegmentId =
	| "plan"
	| "model"
	| "context"
	| "connection"
	| "approvals"
	| "activity"
	| "thinking"
	| "usage"
	| "branch"
	| "unread"
	| "sessions"
	| "mode"
	| "queued"
	| "omp"
	| "session";

interface Segment {
	id: SegmentId;
	text: string;
	slot: ColorSlot;
	/** Lower drops first. Pinned segments are never dropped. */
	priority: number;
	pinned?: boolean;
}

export const GAUGE_CELLS = 8;

/** How often the git branch is re-read. */
export const GIT_POLL_MS = 5000;

export interface StatusBarOptions {
	data: () => StatusBarData;
	/** Working directory to read the branch from; git polling is off without it. */
	cwd?: string;
	readBranch?: (cwd: string) => Promise<string | null>;
	/** Called when the polled branch changed and the row needs a repaint. */
	onChange?: () => void;
	pollMs?: number;
	/** Clicks on the composer's facts ({@link StatusAction}). */
	onNativeAction?: (action: StatusAction) => void;
}

/** What a click on a composer fact asks the host to open or change. */
export type StatusAction = "sessions" | "queue" | "mode" | "approvals" | "cost" | "context" | "omp";

/**
 * The status facts the TSP prompt composer carries instead of a status strip
 * (pi-tui's `ComposerFacts`, shaped for Lemon's data). The same object comes
 * back while nothing changed.
 */
export interface ComposerFacts {
	/**
	 * `meter` (role `omp.composer.context`) along the composer's top edge; only
	 * for a real per-session context measurement, never the daily aggregate.
	 */
	readonly context: NativeNode | undefined;
	/** The model chip's label. */
	readonly model: readonly TspSpan[];
	/** `status` (role `omp.composer.extras`, `grow: 1`) of the other facts as `seg`s. */
	readonly extras: NativeNode;
	/** `text` (role `omp.composer.usage`): the last run's tokens and cost, once reported. */
	readonly usage: NativeNode | undefined;
}

/** Supplies {@link ComposerFacts} and takes the clicks on them (`status.*` actions). */
export interface ComposerFactsSource {
	describeComposerFacts(): ComposerFacts;
	handleNativeEvent(event: NativeUiEvent): void;
}

const STATUS_ACTION_PREFIX = "status.";
const STATUS_ACTIONS: ReadonlySet<string> = new Set<StatusAction>([
	"sessions",
	"queue",
	"mode",
	"approvals",
	"cost",
	"context",
	"omp",
]);
/** The facts the composer draws as its own controls rather than as segments. */
const COMPOSER_HOMED: ReadonlySet<SegmentId> = new Set<SegmentId>([
	"model",
	"activity",
	"thinking",
	"usage",
]);
const FACT_ACTIONS: Partial<Record<SegmentId, StatusAction>> = {
	approvals: "approvals",
	unread: "sessions",
	sessions: "sessions",
	mode: "mode",
	queued: "queue",
	omp: "omp",
};
/** The composer carries the facts, so the TSP dock has no status strip. */
const HIDDEN_STATUS: NativeNode = node("status", { hidden: true });

export class StatusBar implements Component {
	readonly #options: StatusBarOptions;
	#branch: string | null = null;
	#timer: NodeJS.Timeout | undefined;
	#disposed = false;

	#cachedRows: string[] | undefined;
	#cachedWidth = -1;
	#cachedKey = "";
	#facts: { key: string; theme: unknown; facts: ComposerFacts } | undefined;

	constructor(options: StatusBarOptions) {
		this.#options = options;
	}

	/** Start the git poll. No-op without a cwd or a reader. */
	start(): void {
		const { cwd, readBranch, pollMs } = this.#options;
		if (!cwd || !readBranch || this.#timer) return;
		void this.#refreshBranch();
		this.#timer = setInterval(() => void this.#refreshBranch(), pollMs ?? GIT_POLL_MS);
		this.#timer.unref?.();
	}

	/** Re-read the branch now (after a run finishes, a checkout may have moved). */
	async refreshBranch(): Promise<void> {
		await this.#refreshBranch();
	}

	async #refreshBranch(): Promise<void> {
		const { cwd, readBranch } = this.#options;
		if (!cwd || !readBranch || this.#disposed) return;
		const branch = await readBranch(cwd).catch(() => null);
		if (branch === this.#branch) return;
		this.#branch = branch;
		this.#cachedRows = undefined;
		this.#options.onChange?.();
	}

	dispose(): void {
		this.#disposed = true;
		clearInterval(this.#timer);
		this.#timer = undefined;
	}

	invalidate(): void {
		this.#cachedRows = undefined;
	}

	describe(): NativeNode {
		return HIDDEN_STATUS;
	}

	describeComposerFacts(): ComposerFacts {
		const live = this.#options.data();
		const data: StatusBarData = { ...live, branch: live.branch ?? this.#branch };
		const key = cacheKey(data);
		const theme = getTheme();
		if (this.#facts?.key !== key || this.#facts.theme !== theme) {
			this.#facts = { key, theme, facts: buildComposerFacts(data) };
		}
		return this.#facts.facts;
	}

	handleNativeEvent(event: NativeUiEvent): void {
		if (event.type !== "action" || !event.act.startsWith(STATUS_ACTION_PREFIX)) return;
		const action = event.act.slice(STATUS_ACTION_PREFIX.length);
		if (STATUS_ACTIONS.has(action)) this.#options.onNativeAction?.(action as StatusAction);
	}

	render(width: number): readonly string[] {
		const live = this.#options.data();
		const data: StatusBarData = { ...live, branch: live.branch ?? this.#branch };
		const key = cacheKey(data);
		if (this.#cachedRows && this.#cachedWidth === width && this.#cachedKey === key) {
			return this.#cachedRows;
		}
		const rows = [renderStatusLine(data, width)];
		this.#cachedRows = rows;
		this.#cachedWidth = width;
		this.#cachedKey = key;
		return rows;
	}
}

function cacheKey(data: StatusBarData): string {
	return [
		data.sessionKey,
		data.model,
		data.contextTokens,
		data.contextWindow,
		data.contextSource,
		data.runTokens,
		data.runCostUsd,
		data.pendingPrompts,
		data.branch,
		data.sessionCount,
		data.busy,
		data.busySessions,
		data.unread,
		data.approvals,
		data.connection,
		data.mode,
		data.thinking,
		data.engine,
		data.queued,
		data.planMode,
		data.ompBusy,
	].join("\0");
}

/**
 * Build the row. Exported so tests can render at a width without a terminal.
 */
export function renderStatusLine(data: StatusBarData, width: number): string {
	const theme = getTheme();
	const segments = buildSegments(data);
	const separator = " · ";
	// Keep connection recovery and explicit queue counts readable before spending
	// columns on the decorative gauge. Model and context facts stay pinned.
	if (data.connection !== "online") {
		const critical = segments.filter((segment) => segment.pinned || segment.id === "connection");
		if (visibleWidth(critical.map((segment) => segment.text).join(separator)) > width) {
			const context = segments.find((segment) => segment.id === "context");
			if (context)
				context.text = renderGauge(
					data.contextTokens,
					data.contextWindow,
					data.contextSource,
					true,
				);
		}
	}
	const kept = fitSegments(segments, width, separator.length);
	const plain = kept.map((segment) => segment.text).join(separator);
	const styled = kept
		.map((segment) => theme.fg(segment.slot, segment.text))
		.join(theme.fg("dim", separator));
	// Truncation is a last resort: only a terminal too narrow for the pinned
	// segments alone can reach it.
	return visibleWidth(plain) <= width ? styled : truncateToWidth(plain, width);
}

export function buildSegments(data: StatusBarData): Segment[] {
	const segments: Segment[] = [];
	// Plan mode changes what the agent is allowed to do, so it leads the row and
	// is the last optional segment to drop.
	if (data.planMode === "plan") {
		segments.push({ id: "plan", text: "plan", slot: "accent", priority: 95 });
	}

	segments.push({
		id: "model",
		text: shortModel(data.model),
		slot: data.model ? "accent" : "dim",
		priority: 100,
		pinned: true,
	});
	const source = data.contextSource ?? "context";
	segments.push({
		id: "context",
		text: renderGauge(data.contextTokens, data.contextWindow, source),
		slot: source === "context" ? gaugeSlot(data.contextTokens, data.contextWindow) : "dim",
		priority: 99,
		pinned: true,
	});

	if (data.connection !== "online") {
		segments.push({
			id: "connection",
			text: `${data.connection === "auth-rejected" ? "auth rejected" : data.connection === "offline" ? "offline" : `${data.connection}…`}${data.queued > 0 ? ` · ${data.queued} queued` : ""}`,
			slot:
				data.connection === "offline" || data.connection === "auth-rejected" ? "error" : "warning",
			priority: 90,
		});
	}
	if (data.approvals > 0) {
		segments.push({
			id: "approvals",
			text: `${data.approvals} approval${data.approvals === 1 ? "" : "s"}`,
			slot: "warning",
			priority: 85,
		});
	}
	segments.push({
		id: "activity",
		text: data.busy ? (data.engine ? `${data.engine} working` : "working") : "idle",
		slot: data.busy ? "toolRunning" : "dim",
		priority: 80,
	});
	if (data.thinking && data.thinking !== "off") {
		segments.push({ id: "thinking", text: data.thinking, slot: "muted", priority: 40 });
	}
	const usage = runUsage(data);
	if (usage) segments.push({ id: "usage", text: usage, slot: "muted", priority: 55 });
	if (data.branch) {
		segments.push({
			id: "branch",
			text: data.branch,
			slot: data.branch.includes("*") ? "statusLineGitDirty" : "statusLineText",
			priority: 50,
		});
	}
	if (data.unread > 0) {
		segments.push({ id: "unread", text: `${data.unread} unread`, slot: "info", priority: 60 });
	}
	if (data.sessionCount > 1) {
		// `3 sessions ●2` — the dot count is what says work is continuing somewhere
		// the user is not looking. It is left off only when the working/idle
		// segment already accounts for every busy session, which is the single
		// case of "the one on screen is the one working".
		const busyCount = data.busySessions ?? 0;
		const covered = data.busy && busyCount <= 1;
		const marker = busyCount > 0 && !covered ? ` ●${busyCount}` : "";
		segments.push({
			id: "sessions",
			text: `${data.sessionCount} sessions${marker}`,
			slot: marker ? "toolRunning" : "muted",
			priority: busyCount > 0 ? 65 : 30,
		});
	}
	segments.push({
		id: "mode",
		text: data.busy ? `enter:${data.mode} · esc:stop` : data.mode,
		slot: data.busy ? "info" : "dim",
		priority: data.busy ? 82 : 20,
	});
	if ((data.pendingPrompts ?? 0) > 0) {
		segments.push({
			id: "queued",
			text: `${data.pendingPrompts} queued`,
			slot: "info",
			priority: 83,
		});
	}
	if ((data.ompBusy ?? 0) > 0) {
		segments.push({ id: "omp", text: `omp ${data.ompBusy}▶`, slot: "toolRunning", priority: 62 });
	}
	segments.push({ id: "session", text: data.sessionKey, slot: "muted", priority: 10 });

	return segments;
}

/** `last 12k tok $0.0042`, or undefined before a run reported either. */
function runUsage(data: StatusBarData): string | undefined {
	const usage: string[] = [];
	if (data.runTokens !== undefined && Number.isFinite(data.runTokens) && data.runTokens >= 0) {
		usage.push(`${compact(data.runTokens)} tok`);
	}
	if (data.runCostUsd !== undefined && Number.isFinite(data.runCostUsd) && data.runCostUsd >= 0) {
		usage.push(`$${data.runCostUsd.toFixed(data.runCostUsd < 0.01 ? 4 : 2)}`);
	}
	return usage.length > 0 ? `last ${usage.join(" ")}` : undefined;
}

/**
 * The status line's segments, regrouped for the TSP composer: the context
 * meter, the model chip's label and the usage text get their own places; the
 * rest become `omp.composer.fact` segments in row order with their drop
 * priority. The activity segment goes (the composer's tone and Stop button say
 * it), but its engine stays as a fact; the thinking level is the effort chip.
 */
export function buildComposerFacts(data: StatusBarData): ComposerFacts {
	const theme = getTheme();
	const source = data.contextSource ?? "context";
	const facts: NativeNode[] = [];
	for (const segment of buildSegments(data)) {
		if (COMPOSER_HOMED.has(segment.id)) continue;
		// A per-session context is the meter; the daily aggregate stays a plain fact,
		// and only once there is a number to show.
		if (segment.id === "context" && (source === "context" || !data.contextTokens)) continue;
		// Send/Stop already say what Esc does while busy.
		const text = segment.id === "mode" ? `enter:${data.mode}` : segment.text;
		const action = FACT_ACTIONS[segment.id];
		facts.push(
			node(
				"seg",
				{
					role: "omp.composer.fact",
					spans: styledSpans(theme.fg(segment.slot, text)),
					priority: segment.priority,
					...(action ? { actions: { click: `${STATUS_ACTION_PREFIX}${action}` } } : {}),
					...(segment.id === "plan"
						? { title: "Plan mode: read-only until you approve a proposed plan" }
						: {}),
				},
				undefined,
				segment.id,
			),
		);
	}
	if (data.engine) {
		facts.push(
			node(
				"seg",
				{
					role: "omp.composer.fact",
					spans: styledSpans(theme.fg(data.busy ? "toolRunning" : "muted", data.engine)),
					priority: 45,
					title: `Engine: ${data.engine}`,
				},
				undefined,
				"engine",
			),
		);
	}
	const usage = runUsage(data);
	return {
		context:
			source === "context" ? contextMeter(data.contextTokens, data.contextWindow) : undefined,
		model: [span(shortModel(data.model), data.model ? undefined : "dim")],
		extras: node(
			"status",
			{ role: "omp.composer.extras", transparent: true, grow: 1 },
			facts,
			"extras",
		),
		usage:
			usage === undefined
				? undefined
				: node(
						"text",
						{
							role: "omp.composer.usage",
							text: usage,
							wrap: "none",
							title: "Last completed run",
							actions: { click: `${STATUS_ACTION_PREFIX}cost` },
						},
						undefined,
						"usage",
					),
	};
}

/** The composer's context hairline: share of the window, unknown without one. Clicking opens `/context`. */
function contextMeter(
	tokens: number | undefined,
	window: number | undefined,
): NativeNode | undefined {
	if (tokens === undefined || tokens < 0) return undefined;
	return node(
		"meter",
		{
			role: "omp.composer.context",
			...contextMeterProps(tokens, window),
			actions: { click: `${STATUS_ACTION_PREFIX}context` },
		},
		undefined,
		"context",
	);
}

/**
 * One context-share vocabulary for every native meter: the composer hairline
 * and the `/context` sheet show the same value, label, total and thresholds.
 */
export function contextMeterProps(tokens: number, window: number | undefined) {
	const known = window !== undefined && window > 0;
	const used = known ? Math.min(1, tokens / window) : null;
	const lines = [
		used === null ? "Context window unknown" : `Context ${Math.round(used * 100)}% used`,
		known ? `${compact(tokens)} of ${compact(window)} tokens` : `${compact(tokens)} tokens`,
	];
	return {
		value: used,
		style: "bar" as const,
		thresholds: { warn: 0.75, bad: 0.9 },
		...(used === null ? {} : { label: `${Math.round(used * 100)}%` }),
		...(known ? { total: compact(window) } : {}),
		title: lines.join("\n"),
	};
}

/** Drop the lowest-priority optional segments until the row fits. */
export function fitSegments(segments: Segment[], width: number, separatorWidth: number): Segment[] {
	const kept = [...segments];
	const measure = () =>
		kept.reduce(
			(total, segment, index) =>
				total + visibleWidth(segment.text) + (index > 0 ? separatorWidth : 0),
			0,
		);
	while (measure() > width) {
		let victim = -1;
		let lowest = Number.POSITIVE_INFINITY;
		for (let index = 0; index < kept.length; index++) {
			const segment = kept[index];
			if (segment.pinned) continue;
			if (segment.priority < lowest) {
				lowest = segment.priority;
				victim = index;
			}
		}
		if (victim === -1) break;
		kept.splice(victim, 1);
	}
	return kept;
}

/** `anthropic:claude-sonnet-4` -> `claude-sonnet-4`; long ids keep their tail. */
export function shortModel(model: string | undefined): string {
	if (!model) return "no model — /model to choose";
	const withoutProvider = model.includes(":") ? model.slice(model.indexOf(":") + 1) : model;
	return withoutProvider.length > 28 ? `…${withoutProvider.slice(-27)}` : withoutProvider;
}

/**
 * `[▓▓▓░░░░░] 38% 76k/200k`, or just the token count when no window is known —
 * a gauge with an invented denominator would be worse than no gauge.
 *
 * Aggregate tokens never get a bar. `usage.status` totals every session's day, so
 * drawing them against one model's context window would put a number that only
 * goes up inside a meter the user reads as "how full is this conversation". Those
 * render as `use 76k`, which is what they are.
 */
export function renderGauge(
	tokens: number | undefined,
	window: number | undefined,
	source: ContextSource = "context",
	compactDisplay = false,
): string {
	const theme = getTheme();
	const ascii = theme.getSymbolPreset() === "ascii";
	if (source === "aggregate") {
		return tokens && tokens > 0 ? `use ${compact(tokens)}` : "use —";
	}
	if (compactDisplay && window && window > 0)
		return `ctx ${compact(tokens ?? 0)}/${compact(window)}`;
	if (!tokens || tokens <= 0) {
		return window ? `${ascii ? "[--------]" : "[░░░░░░░░]"} 0% 0/${compact(window)}` : "ctx —";
	}
	if (!window || window <= 0) return `ctx ${compact(tokens)}`;
	const ratio = Math.min(1, tokens / window);
	const filled = Math.min(GAUGE_CELLS, Math.round(ratio * GAUGE_CELLS));
	const bar = ascii
		? `${"#".repeat(filled)}${"-".repeat(GAUGE_CELLS - filled)}`
		: `${"▓".repeat(filled)}${"░".repeat(GAUGE_CELLS - filled)}`;
	return `[${bar}] ${Math.round(ratio * 100)}% ${compact(tokens)}/${compact(window)}`;
}

function gaugeSlot(tokens: number | undefined, window: number | undefined): ColorSlot {
	if (!tokens || !window || window <= 0) return "dim";
	const ratio = tokens / window;
	if (ratio >= 0.9) return "error";
	if (ratio >= 0.75) return "warning";
	return "statusLineText";
}

/** 76_000 -> "76k". Deliberately lossy: the gauge is a glance, not a report. */
function compact(value: number): string {
	if (value < 1000) return String(Math.round(value));
	if (value < 1_000_000) return `${Math.round(value / 1000)}k`;
	return `${(value / 1_000_000).toFixed(1)}M`;
}
