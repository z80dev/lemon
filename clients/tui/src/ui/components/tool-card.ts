/**
 * A tool call, as a card.
 *
 * Four lifecycle states, keyed off the block's phase and `ok`
 * ({@link toolCardState}):
 *
 *   streaming   the action was announced, its arguments have not arrived
 *   running     arguments known, result outstanding
 *   success     completed, `ok !== false`
 *   error       completed, `ok === false` or the detail carries an error
 *
 * The card is a header line (status icon or spinner · title · elapsed) over an
 * {@link AccordionComponent} body. The body is the formatter's output for the
 * tool ({@link buildToolView} does the protocol→formatter translation), with a
 * colourised {@link renderDiff} block substituted whenever the action carried
 * structured diff content.
 *
 * Render-contract notes, cribbed from omp's `ToolExecutionComponent`:
 *
 *   - a card that is still running reports **unfinalized**, so the transcript
 *     keeps it (and everything below it) in the repaintable live region — its
 *     spinner and elapsed clock rewrite the header on every tick;
 *   - the spinner animates through `requestComponentRender`, never a full
 *     render, and the frame index is phase-locked across every live card so
 *     parallel spinners advance in lockstep;
 *   - the elapsed reading **freezes at completion**. A finalized card's bytes
 *     must never change again: they may already be in native scrollback.
 */

import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth, visibleWidth } from "@oh-my-pi/pi-tui/utils";
import type { ToolBlock } from "../../store/transcript-model.ts";
import { getTheme, type Theme } from "../theme/theme.ts";
import { buildToolView, type ToolCardState, type ToolView } from "../tool-view.ts";
import { AccordionComponent, type AccordionState, resolveAccordionState } from "./accordion.ts";
import { renderDiff } from "./diff.ts";

/**
 * What the transcript needs from a tool renderer: a component that can be
 * re-driven from the block's current state. {@link ToolShelfComponent} holds
 * these; nothing else constructs one.
 */
export interface ToolBlockComponent extends Component {
	/** Re-render from the block's current state (phase, ok, detail). */
	update(block: ToolBlock): void;
}

/** Redraw live cards at the spinner's glyph rate; faster only repaints identical frames. */
export const SPINNER_INTERVAL_MS = 80;

/** Diff rows a card renders before eliding the rest. */
const MAX_DIFF_ROWS = 24;

/**
 * Phase-locked spinner index: every live card derives its glyph from the same
 * clock, so parallel tools spin together instead of each tracking its own start.
 */
export function sharedSpinnerFrame(frameCount: number, now: number = Date.now()): number {
	return frameCount > 0 ? Math.floor(now / SPINNER_INTERVAL_MS) % frameCount : 0;
}

/** `1.2s`, `47s`, `3m 05s` — stable width-ish, and frozen once the tool ends. */
export function formatElapsed(ms: number): string {
	if (!Number.isFinite(ms) || ms < 0) return "";
	if (ms < 1000) return `${ms}ms`;
	const seconds = ms / 1000;
	if (seconds < 10) return `${seconds.toFixed(1)}s`;
	if (seconds < 60) return `${Math.round(seconds)}s`;
	const minutes = Math.floor(seconds / 60);
	const rest = Math.round(seconds - minutes * 60);
	return `${minutes}m ${String(rest).padStart(2, "0")}s`;
}

/**
 * The glyph a completed action gets. Subagents and reasoning read differently
 * from a plain tool call, so they are marked as such rather than sharing the
 * generic check.
 */
function completedGlyph(kind: string, theme: Theme): string {
	if (theme.getSymbolPreset() === "ascii") {
		return kind === "subagent" ? "@" : kind === "reasoning" || kind === "note" ? "*" : "v";
	}
	if (kind === "subagent") return "◈";
	if (kind === "reasoning" || kind === "note") return "✻";
	return "✓";
}

function errorGlyph(theme: Theme): string {
	return theme.getSymbolPreset() === "ascii" ? "x" : "✗";
}

/** Status icon for a state: a spinner frame while live, a verdict once done. */
export function statusIcon(
	state: ToolCardState,
	kind: string,
	theme: Theme,
	spinnerFrame: number | undefined,
): string {
	switch (state) {
		case "success":
			return theme.fg("toolSuccess", completedGlyph(kind, theme));
		case "error":
			return theme.fg("toolError", errorGlyph(theme));
		default: {
			const frames = theme.spinnerFrames;
			const glyph =
				spinnerFrame === undefined
					? (frames[0] ?? "-")
					: (frames[spinnerFrame % frames.length] ?? "-");
			return theme.fg("toolRunning", glyph);
		}
	}
}

export interface ToolCardOptions {
	/** Component-scoped render hook. Without it the card never animates. */
	requestRender?: (component: Component) => void;
	/** Overrides the per-kind accordion default. */
	accordion?: AccordionState;
	/** Renders as a single shelf line instead of a card. */
	compact?: boolean;
	/** Injectable clock (tests, gallery). */
	now?: () => number;
}

export class ToolCardComponent implements ToolBlockComponent {
	readonly #accordion: AccordionComponent;
	readonly #requestRender: ((component: Component) => void) | undefined;
	readonly #now: () => number;

	#block: ToolBlock;
	#view: ToolView;
	#compact: boolean;
	#startedAt: number;
	/** Set once, at the first completed phase; freezes the elapsed reading. */
	#completedAt: number | undefined;
	#spinnerFrame: number | undefined;
	#spinnerTimer: ReturnType<typeof setInterval> | undefined;

	#version = 0;
	/** Fingerprint of the header's inputs, for no-op detection in #applyView. */
	#headerKey = "";
	#cachedVersion = -1;
	#cachedWidth = -1;
	#cachedAccordion = -1;
	#cached: readonly string[] = [];

	constructor(block: ToolBlock, options: ToolCardOptions = {}) {
		this.#block = block;
		this.#view = buildToolView(block);
		this.#requestRender = options.requestRender;
		this.#now = options.now ?? (() => Date.now());
		this.#compact = options.compact ?? false;
		this.#startedAt = block.at || this.#now();
		this.#accordion = new AccordionComponent(
			options.accordion ?? resolveAccordionState(this.#view.kind),
			{ indent: 2 },
		);
		this.#applyView();
	}

	get view(): ToolView {
		return this.#view;
	}

	get block(): ToolBlock {
		return this.#block;
	}

	get accordion(): AccordionComponent {
		return this.#accordion;
	}

	/**
	 * Re-derive everything from the block's current state.
	 *
	 * Phase regressions are dropped. `SessionStore.upsertTool` already refuses
	 * them, but the guard is repeated here because this is the component that
	 * would actually rewrite the bytes: a card that has reported finalized may
	 * already be in native scrollback, where nothing can be rewritten. The test
	 * is against this card's own recorded completion, not `block.phase` — the
	 * store hands back the same mutable block object, so reading the phase off
	 * the argument would just re-read what the store already decided.
	 */
	update(block: ToolBlock): void {
		if (this.#completedAt !== undefined && block.phase !== "completed") return;
		this.#block = block;
		this.#view = buildToolView(block);
		if (block.phase === "completed" && this.#completedAt === undefined) {
			this.#completedAt = this.#now();
		}
		this.#applyView();
	}

	/** Switch between the full card and the one-line shelf form. */
	setCompact(compact: boolean): void {
		if (this.#compact === compact) return;
		this.#compact = compact;
		this.#version++;
	}

	get compact(): boolean {
		return this.#compact;
	}

	toggleAccordion(): AccordionState {
		const state = this.#accordion.toggle();
		this.#version++;
		return state;
	}

	setAccordionState(state: AccordionState): void {
		this.#accordion.setState(state);
		this.#version++;
	}

	/** Stop animating. Called when the card leaves the tree. */
	dispose(): void {
		if (this.#spinnerTimer === undefined) return;
		clearInterval(this.#spinnerTimer);
		this.#spinnerTimer = undefined;
		this.#spinnerFrame = undefined;
		this.#version++;
	}

	// -- FinalizableBlock ----------------------------------------------------

	isTranscriptBlockFinalized(): boolean {
		return this.#block.phase === "completed";
	}

	getTranscriptBlockVersion(): number {
		return this.#version + this.#accordion.version;
	}

	// -- render --------------------------------------------------------------

	render(width: number): readonly string[] {
		const accordionVersion = this.#accordion.version;
		if (
			this.#cachedVersion === this.#version &&
			this.#cachedWidth === width &&
			this.#cachedAccordion === accordionVersion
		) {
			return this.#cached;
		}
		this.#cachedVersion = this.#version;
		this.#cachedWidth = width;
		this.#cachedAccordion = accordionVersion;
		this.#cached = this.#build(width);
		return this.#cached;
	}

	/** Theme change: the body lines carry baked-in colour, so re-derive them. */
	invalidate(): void {
		this.#cachedVersion = -1;
		this.#cachedWidth = -1;
		this.#applyView();
	}

	/** The single line this card contributes to a {@link ToolShelfComponent}. */
	shelfLine(width: number): string {
		const theme = getTheme();
		const icon = statusIcon(this.#view.state, this.#view.kind, theme, this.#spinnerFrame);
		const title = theme.fg(this.#view.isError ? "toolError" : "toolTitle", this.#view.title);
		const summary = this.#view.summary;
		const head = `${icon} ${title}`;
		if (summary.length === 0) return truncateToWidth(head, width);
		const tail = theme.fg("toolDetail", `  ${summary}`);
		return truncateToWidth(`${head}${tail}`, width);
	}

	#build(width: number): readonly string[] {
		if (this.#compact) return [this.shelfLine(width)];
		const rows: string[] = [this.#header(width)];
		for (const row of this.#accordion.render(width)) rows.push(row);
		return rows;
	}

	#header(width: number): string {
		const theme = getTheme();
		const icon = statusIcon(this.#view.state, this.#view.kind, theme, this.#spinnerFrame);
		const title = theme.fg(this.#view.isError ? "toolError" : "toolTitle", this.#view.title);
		const badge =
			this.#view.kind && this.#view.kind !== "tool" ? theme.fg("dim", ` (${this.#view.kind})`) : "";
		const left = `${icon} ${title}${badge}`;
		const elapsed = this.#elapsedLabel();
		if (elapsed.length === 0) return truncateToWidth(left, width);
		const right = theme.fg("dim", elapsed);
		const gap = width - visibleWidth(left) - visibleWidth(right);
		// No room for both: the title is what matters, the clock can go.
		if (gap < 1) return truncateToWidth(left, width);
		return `${left}${" ".repeat(gap)}${right}`;
	}

	#elapsedLabel(): string {
		if (this.#view.state === "streaming") return "";
		const end = this.#completedAt ?? this.#now();
		const elapsed = formatElapsed(end - this.#startedAt);
		return elapsed;
	}

	/** Rebuild the body and re-evaluate whether the card should be animating. */
	#applyView(): void {
		const summary = this.#view.summary;
		const lines: string[] = [];
		const theme = getTheme();
		if (summary.length > 0) lines.push(theme.fg("toolDetail", summary));
		if (this.#view.diff) {
			for (const row of renderDiff(this.#view.diff.text, {
				path: this.#view.diff.path,
				maxLines: MAX_DIFF_ROWS,
			})) {
				lines.push(row);
			}
		} else {
			const slot = this.#view.isError ? "toolError" : "toolDetail";
			for (const line of this.#view.body) {
				if (line === summary) continue;
				lines.push(theme.fg(slot, line));
			}
		}
		// Only a real change bumps the version. `SessionStore.upsertTool` returns
		// the same mutable block object it already holds, so a replayed frame it
		// refused arrives here as an update whose content is identical — and a
		// version bump alone makes the transcript re-emit rows that never moved.
		const before = this.#accordion.version;
		this.#accordion.setLines(lines);
		this.#accordion.setSummary(summary.length > 0 ? theme.fg("toolDetail", summary) : "");
		const headerKey = `${this.#view.state}|${this.#view.kind}|${this.#view.title}|${this.#view.isError}|${this.#completedAt ?? "-"}`;
		if (headerKey !== this.#headerKey || this.#accordion.version !== before) {
			this.#headerKey = headerKey;
			this.#version++;
		}
		this.#syncAnimation();
	}

	#syncAnimation(): void {
		const live = this.#block.phase !== "completed";
		if (live && this.#requestRender && this.#spinnerTimer === undefined) {
			this.#spinnerFrame = sharedSpinnerFrame(getTheme().spinnerFrames.length, this.#now());
			this.#spinnerTimer = setInterval(() => {
				this.#spinnerFrame = sharedSpinnerFrame(getTheme().spinnerFrames.length, this.#now());
				this.#version++;
				// Component-scoped: a tick only changes this card, so the TUI reuses
				// every other root subtree instead of walking the whole tree.
				this.#requestRender?.(this);
			}, SPINNER_INTERVAL_MS);
			// `unref` keeps a live card from holding the process open at shutdown.
			(this.#spinnerTimer as { unref?: () => void }).unref?.();
			return;
		}
		if (!live) this.dispose();
	}
}
