/**
 * Accordion: the three-state body wrapper tool cards and reasoning blocks use.
 *
 *   hidden     nothing at all (the body is noise for this kind)
 *   collapsed  one summary line, with a hint that there is more
 *   expanded   every line
 *
 * Defaults are per action kind — tools expand (their output is the point),
 * reasoning collapses (it is context, not the answer) — and a global override
 * lets a future `/verbose`-style command flip everything at once without any
 * component knowing about it: components read {@link resolveAccordionState} at
 * construction, and {@link accordionSettings} carries the override.
 *
 * Render discipline: `render()` returns the identical array reference until
 * something actually changes, and every emitted row is truncated to the render
 * width with {@link truncateToWidth} (never `.length` — a styled row's byte
 * count has nothing to do with its column count).
 */

import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth, visibleWidth } from "@oh-my-pi/pi-tui/utils";
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
 * Process-wide accordion preferences. Plain and mutable on purpose: the command
 * layer sets `override` from a slash command and calls `bump()`; components
 * built afterwards pick the new default up. Existing components are left alone
 * (their user may have toggled them by hand).
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

/** Cycle a single accordion: expanded → collapsed → hidden → expanded. */
export function nextAccordionState(state: AccordionState): AccordionState {
	return state === "expanded" ? "collapsed" : state === "collapsed" ? "hidden" : "expanded";
}

export interface AccordionOptions {
	/** Columns of left indentation applied to every emitted row. */
	indent?: number;
	/** Shown after the collapsed summary when there is more to see. */
	moreHint?: (hidden: number) => string;
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

	#version = 0;
	#cachedVersion = -1;
	#cachedWidth = -1;
	#cachedEpoch = -1;
	#cached: readonly string[] = [];

	constructor(state: AccordionState = "expanded", options: AccordionOptions = {}) {
		this.#state = state;
		this.#indent = Math.max(0, options.indent ?? 2);
		this.#moreHint = options.moreHint ?? ((hidden) => `+${hidden} more`);
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
		const inner = Math.max(1, width - this.#indent);
		const pad = " ".repeat(this.#indent);
		if (this.#state === "collapsed") {
			const theme = getTheme();
			const summary = this.#summary || this.#lines[0] || "";
			const hidden = this.#lines.length - 1;
			const hint = hidden > 0 ? theme.fg("dim", ` ${this.#moreHint(hidden)}`) : "";
			const room = Math.max(1, inner - visibleWidth(hint));
			return [`${pad}${truncateToWidth(summary, room)}${hint}`];
		}
		const out: string[] = new Array(this.#lines.length);
		for (let i = 0; i < this.#lines.length; i++) {
			out[i] = `${pad}${truncateToWidth(this.#lines[i] ?? "", inner)}`;
		}
		return out;
	}
}

const EMPTY: readonly string[] = [];
