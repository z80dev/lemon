/**
 * `/context`: where the focused session's context window goes.
 *
 * A dismissible overlay over one immutable `sessions.context` receipt. The row
 * renderer draws omp's occupancy map (pi-tui `planContextMap`: 100 cells, one per
 * percent of the window, colored per category, free space and part-covered cells dimmed), a per-category table whose rows sum to the
 * measured total, compaction headroom, the largest contributors and the
 * measurement caveats. Tern's native backend gets the same facts as semantic
 * nodes instead: a stacked `meter`, `table`s and notes inside a glass sheet.
 *
 * Nothing here estimates anything. The receipt's totals are the daemon's; the
 * panel only lays them out and says which parts were estimated.
 */

import {
	type ContextMapCell,
	type ContextMapSegment,
	planContextMap,
} from "@oh-my-pi/pi-tui/chrome/context-map";
import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import { col, node, row, span, text } from "@oh-my-pi/pi-tui/native/describe";
import type {
	DescribeContext,
	NativeNode,
	NativeUiEvent,
	TspSpan,
} from "@oh-my-pi/pi-tui/native/node";
import { actionBar, actionButton } from "@oh-my-pi/pi-tui/native/overlay";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth, visibleWidth, wrapTextWithAnsi } from "@oh-my-pi/pi-tui/utils";
import { humanNumber } from "../../commands/format.ts";
import type { ContextCategoryId, SessionsContextResult } from "../../protocol/types.ts";
import { type ColorSlot, getTheme } from "../theme/theme.ts";
import { contextMeterProps } from "./status-bar.ts";

/** The occupancy map is planned as 25 × 4 cells: one per percent of the window. */
const CONTEXT_GRID_COLUMNS = 25;
const CONTEXT_GRID_ROWS = 4;
export const CONTEXT_GRID_CELLS = CONTEXT_GRID_COLUMNS * CONTEXT_GRID_ROWS;

/**
 * Category colors. The slot names double as Tern theme tokens, so both
 * renderers paint a category the same way.
 */
const CATEGORY_SLOTS: Readonly<Record<ContextCategoryId | "other", ColorSlot>> = {
	system_prompt: "toolTitle",
	tool_definitions: "info",
	skills: "syntaxType",
	context_files: "accent",
	memory: "syntaxNumber",
	user_messages: "success",
	assistant_messages: "text",
	tool_results: "error",
	summaries: "muted",
	unattributed: "warning",
	other: "dim",
};

const SOURCE_LABELS: Readonly<Record<SessionsContextResult["source"], string>> = {
	usage: "provider-reported",
	"usage+estimate": "reported + estimated",
	estimate: "estimated",
};

const OVERHEAD_NOTES: Readonly<Record<SessionsContextResult["overhead"], string>> = {
	live: "System prompt and tools are measured live from the running session.",
	snapshot: "System prompt and tools are a snapshot measured at the end of the last turn.",
	unavailable:
		"System prompt and tools were never recorded for this session, so their share is not itemized.",
};

const OTHER_LABEL = "Other (categories this client does not know)";
/** Tables and prose stop here on wide terminals so numbers stay next to their labels. */
const TABLE_WIDTH = 64;
const PROSE_WIDTH = 80;

interface Glyphs {
	used: string;
	free: string;
}

const GLYPHS: Readonly<Record<"unicode" | "ascii", Glyphs>> = {
	unicode: { used: "■", free: "·" },
	ascii: { used: "#", free: "." },
};

interface Slice {
	key: ContextCategoryId | "other";
	label: string;
	tokens: number;
}

export interface ContextPanelOptions {
	rows: () => number;
	close: () => void;
	repaint: () => void;
}

export class ContextPanelComponent implements Component {
	/** Tern draws the frame: a centred glass sheet with this title. */
	readonly nativeOverlay = {
		role: "omp.overlay.context",
		size: "lg",
		anchor: "center",
		head: "Context window",
	} as const;
	readonly usage: SessionsContextResult;
	readonly #options: ContextPanelOptions;
	#offset = 0;
	#bodyWidth = -1;
	#header: string[] = [];
	#body: string[] = [];
	#rows: readonly string[] | undefined;
	#rowsKey = "";
	#native: { key: string; node: NativeNode | null } | undefined;

	constructor(usage: SessionsContextResult, options: ContextPanelOptions) {
		this.usage = usage;
		this.#options = options;
	}

	get offset(): number {
		return this.#offset;
	}

	get totalRows(): number {
		return this.#body.length;
	}

	invalidate(): void {
		this.#bodyWidth = -1;
		this.#rows = undefined;
	}

	handleInput(data: string): void {
		if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c") || data === "q") {
			this.#options.close();
			return;
		}
		const page = this.#pageSize();
		let offset = this.#offset;
		if (matchesKey(data, "down") || data === "j") offset++;
		else if (matchesKey(data, "up") || data === "k") offset--;
		else if (matchesKey(data, "pageDown") || data === " ") offset += page;
		else if (matchesKey(data, "pageUp")) offset -= page;
		else if (matchesKey(data, "home") || data === "g") offset = 0;
		else if (matchesKey(data, "end") || data === "G") offset = this.#body.length - page;
		else return;
		this.#offset = Math.max(0, Math.min(offset, this.#body.length - page));
		this.#options.repaint();
	}

	/** The Close button runs Escape's path. */
	handleNativeEvent(event: NativeUiEvent): void {
		if (event.type === "action" && event.act === "close") this.#options.close();
	}

	render(width: number): readonly string[] {
		if (width < 1) return EMPTY;
		if (this.#bodyWidth !== width) {
			this.#bodyWidth = width;
			this.#header = contextPanelHeader(this.usage, width);
			this.#body = contextPanelBody(this.usage, width);
			this.#rows = undefined;
		}
		const page = this.#pageSize();
		this.#offset = Math.max(0, Math.min(this.#offset, this.#body.length - page));
		const key = `${width}|${page}|${this.#offset}`;
		if (this.#rows && this.#rowsKey === key) return this.#rows;
		const shown = this.#body.slice(this.#offset, this.#offset + page);
		const total = this.#body.length;
		const position = total ? `${this.#offset + 1}–${this.#offset + shown.length}/${total}` : "0/0";
		const keys =
			width >= 60 ? "↑↓/pgup/pgdn scroll · g/G first/last · esc close" : "↑↓ scroll · esc close";
		this.#rows = [
			...this.#header,
			...shown,
			truncateToWidth(getTheme().fg("dim", `${position} · ${keys}`), width),
		];
		this.#rowsKey = key;
		return this.#rows;
	}

	/**
	 * Semantic sheet body. The receipt never changes under a panel, so the node
	 * is built once per terminal vocabulary and returned by reference after.
	 */
	describe(cx: DescribeContext): NativeNode | null {
		const key = `${cx.supports("meter")}|${cx.supports("table")}|${cx.supports("kv")}`;
		if (this.#native?.key !== key) {
			this.#native = {
				key,
				node: cx.supports("table") && cx.supports("kv") ? describeContext(this.usage, cx) : null,
			};
		}
		return this.#native.node;
	}

	/** Body rows visible between the pinned header and the footer. */
	#pageSize(): number {
		return Math.max(1, this.#options.rows() - Math.max(2, this.#header.length) - 1);
	}
}

const EMPTY: readonly string[] = Object.freeze([]);

// -- row renderer -----------------------------------------------------------

/** Headline and facts, wrapped (never truncated) and pinned above the scrolling body. */
export function contextPanelHeader(usage: SessionsContextResult, width: number): string[] {
	const theme = getTheme();
	return [
		...wrapTextWithAnsi(headline(usage), width).map((line) => theme.fg("toolTitle", line)),
		...wrapTextWithAnsi(facts(usage).join(" · "), width).map((line) => theme.fg("dim", line)),
	];
}

/** Everything below the header, at `width`; never wider. Tables stop at a readable width. */
export function contextPanelBody(usage: SessionsContextResult, width: number): string[] {
	const theme = getTheme();
	const glyph = GLYPHS[theme.getSymbolPreset()];
	const table = Math.min(width, TABLE_WIDTH);
	const lines: string[] = [];
	const wrap = (line: string, slot: ColorSlot = "text") => {
		for (const part of wrapTextWithAnsi(line, Math.min(width, PROSE_WIDTH))) {
			lines.push(theme.fg(slot, part));
		}
	};

	lines.push("");
	lines.push(...grid(usage, width, glyph));
	lines.push("");

	const slices = slicesOf(usage);
	const free = usage.freeTokens;
	const tokenWidth = Math.max(
		...slices.map((slice) => exact(slice.tokens).length),
		exact(usage.usedTokens).length,
		free === null ? 0 : exact(free).length,
	);
	const showPercent = table >= 30;
	const tableRow = (
		glyph: string,
		label: string,
		tokens: number,
		percent: number | null,
		dim: boolean,
	) => {
		const numbers = `${exact(tokens).padStart(tokenWidth)}${showPercent ? `  ${percentText(percent).padStart(6)}` : ""}`;
		const labelWidth = Math.max(1, table - 2 - 2 - numbers.length);
		const shown = truncateToWidth(label, labelWidth);
		const padded = `${shown}${" ".repeat(Math.max(0, labelWidth - visibleWidth(shown)))}`;
		const body = `${padded}  ${numbers}`;
		return truncateToWidth(`${glyph} ${dim ? theme.fg("dim", body) : body}`, width);
	};
	for (const slice of slices) {
		const mark = slice.tokens > 0 ? theme.fg(CATEGORY_SLOTS[slice.key], glyph.used) : " ";
		lines.push(
			tableRow(mark, slice.label, slice.tokens, percentOf(usage, slice), slice.tokens === 0),
		);
	}
	if (free !== null) {
		lines.push(
			tableRow(theme.fg("dim", glyph.free), "Free space", free, freePercent(usage), false),
		);
	}
	lines.push(truncateToWidth(theme.fg("dim", theme.hrChar.repeat(table)), width));
	lines.push(tableRow(" ", "Used", usage.usedTokens, usage.percentUsed, false));

	const compaction = compactionText(usage);
	if (compaction) {
		lines.push("");
		wrap(compaction, usage.autoCompaction?.enabled ? "text" : "muted");
	}

	if (usage.top.length > 0) {
		lines.push("");
		lines.push(truncateToWidth(theme.fg("toolTitle", "Largest contributors"), width));
		const topWidth = Math.max(...usage.top.map((entry) => exact(entry.tokens).length));
		for (const entry of usage.top) {
			const numbers = exact(entry.tokens).padStart(topWidth);
			const labelWidth = Math.max(1, table - 4 - 2 - numbers.length);
			const shown = truncateToWidth(entry.label, labelWidth);
			const padded = `${shown}${" ".repeat(Math.max(0, labelWidth - visibleWidth(shown)))}`;
			const mark = theme.fg(CATEGORY_SLOTS[entry.category ?? "other"], glyph.used);
			lines.push(truncateToWidth(`  ${mark} ${padded}  ${numbers}`, width));
		}
	}

	lines.push("");
	for (const note of notes(usage)) wrap(note, "muted");
	return lines;
}

/** The 100-cell grid; each row a fixed number of cells that fits `width`. */
function grid(usage: SessionsContextResult, width: number, glyph: Glyphs): string[] {
	const theme = getTheme();
	const columns = [50, 25, 20, 10].find((candidate) => candidate <= width) ?? Math.max(1, width);
	const cells = gridCells(usage);
	const rows: string[] = [];
	for (let start = 0; start < cells.length; start += columns) {
		rows.push(
			cells
				.slice(start, start + columns)
				.map((cell) => {
					if (cell.id === "free") return theme.fg("dim", glyph.free);
					const painted = theme.fg(CATEGORY_SLOTS[cell.id], glyph.used);
					// Like omp's map, a cell its category covers less than 70% is dimmed.
					return cell.full ? painted : `\x1b[2m${painted}\x1b[22m`;
				})
				.join(""),
		);
	}
	return rows;
}

/**
 * Lay the window out as omp's occupancy map does: the categories in contract
 * order, then free space, over a `CONTEXT_GRID_CELLS`-cell grid (one cell per
 * percent), each cell taking the segment covering most of it. Without a window,
 * or past it, the grid spans only what is used and shows its composition.
 */
export function gridCells(usage: SessionsContextResult): ContextMapCell<Slice["key"] | "free">[] {
	const segments: ContextMapSegment<Slice["key"] | "free">[] = slicesOf(usage).map((slice) => ({
		id: slice.key,
		tokens: slice.tokens,
	}));
	const window = usage.window;
	const bounded = window !== null && usage.usedTokens <= window;
	if (bounded && usage.freeTokens !== null) {
		segments.push({ id: "free", tokens: usage.freeTokens });
	}
	const base = bounded ? window : usage.usedTokens;
	const cells = planContextMap(segments, base, CONTEXT_GRID_COLUMNS, CONTEXT_GRID_ROWS);
	while (cells.length < CONTEXT_GRID_CELLS) cells.push({ id: "free", full: true });
	return cells;
}

// -- native -----------------------------------------------------------------

function describeContext(usage: SessionsContextResult, cx: DescribeContext): NativeNode {
	const slices = slicesOf(usage);
	const children: NativeNode[] = [
		row(
			[
				text([span(headline(usage), "strong")], { grow: 1, shrink: 1, truncate: "end" }),
				text(
					[
						span(totals(usage), "mono muted"),
						...(usage.percentUsed === null
							? []
							: [span("  "), span(`${usage.percentUsed}%`, "mono strong")]),
					],
					{ wrap: "none", shrink: 0 },
				),
			],
			{ align: "baseline", role: "omp.info.contextHead" },
		),
		text([span(facts(usage).join(" · "), "muted")], { wrap: "word" }),
		meter(usage, slices, cx.supports("meter")),
		node("table", {
			cols: [
				{ id: "category", head: "Category", grow: 1, truncate: "end", priority: 3 },
				{ id: "tokens", head: "Tokens", align: "end", priority: 2 },
				{ id: "share", head: "% of window", align: "end", priority: 1 },
			],
			rows: [
				...slices.map((slice) => ({
					id: slice.key,
					cells: {
						category: categoryCell(slice.key, slice.label, slice.tokens === 0),
						tokens: numberCell(exact(slice.tokens), slice.tokens === 0),
						share: numberCell(percentText(percentOf(usage, slice)), slice.tokens === 0),
					},
				})),
				...(usage.freeTokens === null
					? []
					: [
							{
								id: "free",
								cells: {
									category: [span("Free space", "dim")],
									tokens: numberCell(exact(usage.freeTokens), true),
									share: numberCell(percentText(freePercent(usage)), true),
								},
							},
						]),
				{
					id: "used",
					cells: {
						category: [span("Used", "strong")],
						tokens: [span(exact(usage.usedTokens), "num strong")],
						share: [span(percentText(usage.percentUsed), "num strong")],
					},
				},
			],
		}),
	];
	const compaction = compactionText(usage);
	if (compaction) {
		children.push(
			text([span(compaction, usage.autoCompaction?.enabled ? undefined : "muted")], {
				wrap: "word",
			}),
		);
	}
	if (usage.top.length > 0) {
		children.push(
			node("section", { head: "Largest contributors" }, [
				node("table", {
					cols: [
						{ id: "label", head: "Item", grow: 1, truncate: "end", priority: 2 },
						{ id: "tokens", head: "Tokens", align: "end", priority: 1 },
					],
					rows: usage.top.map((entry, index) => ({
						id: `top-${index}`,
						cells: {
							label: categoryCell(entry.category ?? "other", entry.label, false),
							tokens: numberCell(exact(entry.tokens), false),
						},
					})),
				}),
			]),
		);
	}
	for (const note of notes(usage)) {
		children.push(text([span(note, "muted")], { wrap: "word", role: "omp.info.note" }));
	}
	children.push(actionBar([null, actionButton("Close", "close", { keys: "escape" })]));
	return col(children, { gap: "md", role: "omp.context" });
}

/** The composer's context meter (same value, label, total, thresholds), split into categories. */
function meter(usage: SessionsContextResult, slices: Slice[], supportsMeter: boolean): NativeNode {
	const window = usage.window ?? undefined;
	const shared = contextMeterProps(usage.usedTokens, window);
	if (!supportsMeter) return node("progress", { value: shared.value });
	const base = window === undefined || usage.usedTokens > window ? usage.usedTokens : window;
	const compaction = usage.autoCompaction;
	return node("meter", {
		...shared,
		size: "md",
		parts:
			base > 0
				? slices
						.filter((slice) => slice.tokens > 0)
						.map((slice) => ({
							value: slice.tokens / base,
							token: CATEGORY_SLOTS[slice.key],
							label: slice.label,
						}))
				: [],
		...(window !== undefined && compaction?.enabled
			? {
					marks: [
						{
							at: Math.min(1, compaction.thresholdTokens / window),
							icon: "context.compaction",
							title: `Auto-compaction at ${exact(compaction.thresholdTokens)} tokens`,
						},
					],
				}
			: {}),
	});
}

function categoryCell(key: Slice["key"], label: string, dim: boolean): TspSpan[] {
	return [span("■", CATEGORY_SLOTS[key]), span(" "), span(label, dim ? "dim" : undefined)];
}

function numberCell(value: string, dim: boolean): TspSpan[] {
	return [span(value, dim ? "num dim" : "num")];
}

// -- shared facts -------------------------------------------------------------

/** Categories in contract order, plus a remainder row for unknown ids. */
function slicesOf(usage: SessionsContextResult): Slice[] {
	const slices: Slice[] = usage.categories.map((category) => ({
		key: category.id,
		label: category.label,
		tokens: category.tokens,
	}));
	if (usage.otherTokens > 0) {
		slices.push({ key: "other", label: OTHER_LABEL, tokens: usage.otherTokens });
	}
	return slices;
}

/** `claude-sonnet-4-5 · 45.2k/200k tokens (22.6%)`. */
function headline(usage: SessionsContextResult): string {
	const model = usage.model?.id ?? "unknown model";
	const percent = usage.percentUsed === null ? "" : ` (${usage.percentUsed}%)`;
	return `${model} · ${totals(usage)} tokens${percent}`;
}

function totals(usage: SessionsContextResult): string {
	return usage.window === null
		? `${humanNumber(usage.usedTokens)}/? (window unknown)`
		: `${humanNumber(usage.usedTokens)}/${humanNumber(usage.window)}`;
}

function facts(usage: SessionsContextResult): string[] {
	return [
		SOURCE_LABELS[usage.source],
		usage.live ? "live session" : "stored session",
		...(usage.messageCount === undefined ? [] : [`${usage.messageCount} messages`]),
	];
}

function compactionText(usage: SessionsContextResult): string | undefined {
	const compaction = usage.autoCompaction;
	if (!compaction || usage.window === null) return undefined;
	const at = `${exact(compaction.thresholdTokens)} tokens (${percentText((compaction.thresholdTokens / usage.window) * 100)})`;
	if (!compaction.enabled) return `Auto-compaction is off; its threshold would be ${at}.`;
	const parts = [`Auto-compaction at ${at}`];
	if (compaction.headroomTokens !== undefined)
		parts.push(`${exact(compaction.headroomTokens)} tokens of headroom`);
	if (compaction.reserveTokens !== undefined)
		parts.push(`${exact(compaction.reserveTokens)} reserved`);
	return `${parts.join(" · ")}.`;
}

function notes(usage: SessionsContextResult): string[] {
	const raw =
		usage.estimatedTokens !== undefined && usage.estimatedTokens !== usage.usedTokens
			? ` Raw estimate before scaling: ${exact(usage.estimatedTokens)} tokens.`
			: "";
	return [
		OVERHEAD_NOTES[usage.overhead],
		usage.source === "estimate"
			? "No provider usage yet: the total and every split are estimates (≈4 chars/token)."
			: `Category splits are estimates (≈4 chars/token) normalized to the reported total.${raw}`,
	];
}

function percentOf(usage: SessionsContextResult, slice: Slice): number | null {
	if (slice.key !== "other") {
		return usage.categories.find((category) => category.id === slice.key)?.percent ?? null;
	}
	return usage.window === null ? null : (slice.tokens / usage.window) * 100;
}

function freePercent(usage: SessionsContextResult): number | null {
	return usage.window === null || usage.freeTokens === null
		? null
		: (usage.freeTokens / usage.window) * 100;
}

function percentText(value: number | null): string {
	return value === null ? "—" : `${(Math.round(value * 10) / 10).toFixed(1)}%`;
}

function exact(value: number): string {
	return value.toLocaleString("en-US");
}
