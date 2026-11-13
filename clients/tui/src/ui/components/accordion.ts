/**
 * Accordion: the three-state body wrapper tool cards and reasoning blocks use.
 *
 *   hidden     nothing at all (the body is noise for this kind)
 *   collapsed  one summary line, with a hint that there is more
 *   expanded   every line
 *
 * Defaults are per action kind — tools expand (their output is the point),
 * reasoning collapses (it is context, not the answer). Alt+E toggles the latest
 * card or reasoning block ({@link nextAccordionState}); Ctrl+T cycles a global
 * override carried by {@link accordionSettings}: components read
 * {@link resolveAccordionState} at construction, and the event controller
 * re-applies it to the ones already on screen when the override changes.
 *
 * Render discipline: `render()` returns the identical array reference until
 * something actually changes, and every emitted row is truncated to the render
 * width with {@link truncateToWidth} (never `.length` — a styled row's byte
 * count has nothing to do with its column count).
 */

import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth, visibleWidth, wrapTextWithAnsi } from "@oh-my-pi/pi-tui/utils";
import { getTheme } from "../theme/theme.ts";

export type AccordionState = "hidden" | "collapsed" | "expanded";

/** Per-kind defaults. Anything unlisted expands. */
const KIND_DEFAULTS: Record<string, AccordionState> = {
	reasoning: "collapsed",
	note: "collapsed",
	tool: "expanded",
	command: "expanded",
	file_change: "expanded",
	web_search: "expanded",
	subagent: "expanded",
};

/**
 * Process-wide accordion preferences. Plain and mutable on purpose: Ctrl+T calls
 * {@link accordionSettings.cycleOverride}; components built afterwards pick the
 * new default up, and `EventController.cycleAccordionOverride` re-applies it to
 * the existing ones.
 */
export const accordionSettings = {
	/** When set, wins over every per-kind default. */
	override: undefined as AccordionState | undefined,
	/** Bumped whenever the settings change, so callers can memoize on it. */
	epoch: 0,

	setOverride(state: AccordionState | undefined): void {
		if (this.override === state) return;
		this.override = state;
		this.epoch++;
	},

	/** Cycle the global override: default → collapsed → expanded → default. */
	cycleOverride(): AccordionState | undefined {
		const next =
			this.override === undefined
				? "collapsed"
				: this.override === "collapsed"
					? "expanded"
					: undefined;
		this.setOverride(next);
		return next;
	},

	reset(): void {
		this.setOverride(undefined);
	},
};

/** The state a freshly built accordion for `kind` should start in. */
export function resolveAccordionState(kind: string | undefined): AccordionState {
	return accordionSettings.override ?? KIND_DEFAULTS[kind ?? ""] ?? "expanded";
}

/**
 * Toggle a single accordion: expanded ↔ collapsed. A hidden body (only ever set
 * by the global override) opens fully — the keypress asked to see it.
 */
export function nextAccordionState(state: AccordionState): AccordionState {
	return state === "expanded" ? "collapsed" : "expanded";
}

export interface AccordionOptions {
	/** Columns of left indentation applied to every emitted row. */
	indent?: number;
	/** Shown after the collapsed summary when there is more to see. */
	moreHint?: (hidden: number) => string;
	/** Word-wrap expanded lines at the render width instead of truncating them. */
	wrap?: boolean;
}

/**
 * Body lines under a header, in one of three states.
 *
 * The lines handed in are pre-styled (a formatter's output, a rendered diff);
 * the accordion only indents, truncates and elides them.
 */
export class AccordionComponent implements Component {
	#lines: readonly string[] = [];
	#summary = "";
	#state: AccordionState;
	#indent: number;
	#moreHint: (hidden: number) => string;
	#wrap: boolean;

	#version = 0;
	#cachedVersion = -1;
	#cachedWidth = -1;
	#cachedEpoch = -1;
	#cached: readonly string[] = [];

	constructor(state: AccordionState = "expanded", options: AccordionOptions = {}) {
		this.#state = state;
		this.#indent = Math.max(0, options.indent ?? 2);
		this.#moreHint = options.moreHint ?? ((hidden) => `+${hidden} more`);
		this.#wrap = options.wrap ?? false;
	}

	get state(): AccordionState {
		return this.#state;
	}

	get lineCount(): number {
		return this.#lines.length;
	}

	/** Bumped by every mutation; the card folds it into its own block version. */
	get version(): number {
		return this.#version;
	}

	setState(state: AccordionState): void {
		if (this.#state === state) return;
		this.#state = state;
		this.#version++;
	}

	toggle(): AccordionState {
		this.setState(nextAccordionState(this.#state));
		return this.#state;
	}

	/** Replace the body. Reference-equal lines are a no-op. */
	setLines(lines: readonly string[]): void {
		if (lines === this.#lines) return;
		if (lines.length === this.#lines.length && lines.every((line, i) => line === this.#lines[i])) {
			return;
		}
		this.#lines = lines;
		this.#version++;
	}

	/** The single line shown when collapsed. Defaults to the first body line. */
	setSummary(summary: string): void {
		if (summary === this.#summary) return;
		this.#summary = summary;
		this.#version++;
	}

	render(width: number): readonly string[] {
		const epoch = accordionSettings.epoch;
		if (
			this.#cachedVersion === this.#version &&
			this.#cachedWidth === width &&
			this.#cachedEpoch === epoch
		) {
			return this.#cached;
		}
		this.#cachedVersion = this.#version;
		this.#cachedWidth = width;
		this.#cachedEpoch = epoch;
		this.#cached = this.#build(width);
		return this.#cached;
	}

	#build(width: number): readonly string[] {
		if (this.#state === "hidden" || this.#lines.length === 0) return EMPTY;
		// The indent is a preference, not an entitlement: at a width narrower than
		// the indent itself, `pad + truncateToWidth(line, 1)` would emit more
		// columns than the caller asked for. Give the content at least one column
		// and spend whatever is left on indentation.
		if (width < 1) return EMPTY;
		const indent = Math.min(this.#indent, width - 1);
		const inner = width - indent;
		const pad = " ".repeat(indent);
		if (this.#state === "collapsed") {
			const theme = getTheme();
			const summary = this.#summary || this.#lines[0] || "";
			const hidden = this.#lines.length - 1;
			const hint = hidden > 0 ? theme.fg("dim", ` ${this.#moreHint(hidden)}`) : "";
			const hintWidth = visibleWidth(hint);
			// The hint is the first thing to go when it cannot coexist with at least
			// one column of the summary it is annotating.
			const fits = hintWidth > 0 && hintWidth + 1 <= inner;
			const room = fits ? inner - hintWidth : inner;
			return [`${pad}${truncateToWidth(summary, room)}${fits ? hint : ""}`];
		}
		const out: string[] = [];
		for (const line of this.#lines) {
			if (this.#wrap) {
				for (const row of wrapTextWithAnsi(line, inner)) out.push(`${pad}${row}`);
			} else {
				out.push(`${pad}${truncateToWidth(line, inner)}`);
			}
		}
		return out;
	}
}

const EMPTY: readonly string[] = [];
