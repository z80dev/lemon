/**
 * Smooth streaming reveal, ported from omp's
 * `src/modes/controllers/streaming-reveal.ts`.
 *
 * The daemon delivers deltas in bursts; painting each burst verbatim makes the
 * reply lurch. This controller keeps a reveal cursor that advances on a 30fps
 * timer, catching up when the backlog grows (see {@link nextStep}) so the text
 * never falls behind by more than about {@link CATCHUP_FRAMES} frames.
 *
 * Two properties are load-bearing:
 *   - the cursor counts *graphemes*, never code units, so a reveal boundary can
 *     never land inside an emoji or a combining sequence;
 *   - each tick renders through `requestComponentRender(component)`, never a
 *     full-tree render. A full walk at 30fps costs several percent of CPU on
 *     its own and cascades into container overhead (omp issue #4377).
 *
 * omp reveals a multi-block `AssistantMessage` (text + thinking); lemon streams
 * one text channel per run, so the block loop collapses into a single string
 * and the memoization keeps only one entry.
 */

import type { Component } from "@oh-my-pi/pi-tui/tui";
import { getSegmenter } from "@oh-my-pi/pi-tui/utils";

export const STREAMING_REVEAL_FRAME_MS = 1000 / 30;
export const MIN_STEP = 3;
export const CATCHUP_FRAMES = 8;

/** The reveal target: an {@link AssistantMessageComponent}, in practice. */
export type StreamingRevealComponent = Component & {
	updateContent(text: string, options?: { transient?: boolean }): void;
};

export interface StreamingRevealOptions {
	/**
	 * Called after each tick with the component whose subtree changed. Scope the
	 * render to that subtree — a full-tree render here runs 30 times a second.
	 */
	requestRender(component: Component): void;
	/** When false the reveal is skipped and text lands whole. Defaults to true. */
	getSmoothStreaming?(): boolean;
}

/** Grapheme count of `text` from code-unit offset `start`, plus the start
 *  offset of the final cluster (where an append could extend a cluster). */
function countGraphemesFrom(text: string, start: number): { count: number; tailStart: number } {
	let count = 0;
	let tailStart = start;
	for (const segment of getSegmenter().segment(start === 0 ? text : text.slice(start))) {
		count += 1;
		tailStart = start + segment.index;
	}
	return { count, tailStart };
}

/** Segment `text` from code-unit offset `start`, walking up to `clusters`
 *  graphemes. Returns the code-unit END of the final cluster walked, its START
 *  (`lastStart`), and how many clusters were found (`count` may be less than
 *  `clusters` when the suffix is shorter than requested). */
function segmentFrom(
	text: string,
	start: number,
	clusters: number,
): { end: number; lastStart: number; count: number } {
	let count = 0;
	let lastStart = start;
	let end = start;
	for (const segment of getSegmenter().segment(start === 0 ? text : text.slice(start))) {
		count += 1;
		lastStart = start + segment.index;
		end = start + segment.index + segment.segment.length;
		if (count >= clusters) break;
	}
	return { end, lastStart, count };
}

/**
 * Memoizes grapheme counts and prefix slices for one append-only stream. A
 * streaming buffer only grows by appending, and an append can only alter the
 * final grapheme cluster of the previous text, so re-segmenting the suffix from
 * that cluster is enough — which turns the reveal from O(N²) into O(N) over a
 * long reply.
 */
export class StreamUnitCounter {
	#entry: { text: string; count: number; tailStart: number } | undefined;
	#slice: { text: string; units: number; end: number; lastStart: number } | undefined;

	count(text: string): number {
		if (text.length === 0) return 0;
		const entry = this.#entry;
		if (entry !== undefined) {
			if (entry.text === text) return entry.count;
			if (entry.count > 0 && text.length > entry.text.length && text.startsWith(entry.text)) {
				const tail = countGraphemesFrom(text, entry.tailStart);
				const next = { text, count: entry.count - 1 + tail.count, tailStart: tail.tailStart };
				this.#entry = next;
				return next.count;
			}
		}
		const full = countGraphemesFrom(text, 0);
		this.#entry = { text, count: full.count, tailStart: full.tailStart };
		return full.count;
	}

	/**
	 * `text` cut to its first `units` graphemes. Only an exact (text, units) hit
	 * skips segmentation entirely — an append can extend the boundary cluster,
	 * so the incremental path still re-segments from that cluster's start.
	 */
	slice(text: string, units: number): string {
		if (units <= 0 || text.length === 0) return "";
		const entry = this.#slice;
		if (entry !== undefined && entry.text === text && entry.units === units) {
			return entry.end >= text.length ? text : text.slice(0, entry.end);
		}
		if (entry !== undefined && text.startsWith(entry.text) && units >= entry.units) {
			const extra = units - entry.units + 1;
			const segment = segmentFrom(text, entry.lastStart, extra);
			this.#slice = { text, units, end: segment.end, lastStart: segment.lastStart };
			return segment.end >= text.length ? text : text.slice(0, segment.end);
		}
		const segment = segmentFrom(text, 0, units);
		this.#slice = { text, units, end: segment.end, lastStart: segment.lastStart };
		return segment.end >= text.length ? text : text.slice(0, segment.end);
	}

	reset(): void {
		this.#entry = undefined;
		this.#slice = undefined;
	}
}

/** Graphemes to reveal this frame: enough to clear the backlog in
 *  {@link CATCHUP_FRAMES} frames, never fewer than {@link MIN_STEP}. */
export function nextStep(backlog: number): number {
	return Math.max(MIN_STEP, Math.ceil(Math.max(0, backlog) / CATCHUP_FRAMES));
}

export class StreamingRevealController {
	readonly #requestRender: (component: Component) => void;
	readonly #getSmoothStreaming: () => boolean;
	readonly #counter = new StreamUnitCounter();

	#component: StreamingRevealComponent | undefined;
	#target = "";
	#revealed = 0;
	#timer: ReturnType<typeof setInterval> | undefined;

	constructor(options: StreamingRevealOptions) {
		this.#requestRender = options.requestRender;
		this.#getSmoothStreaming = options.getSmoothStreaming ?? (() => true);
	}

	get revealedUnits(): number {
		return this.#revealed;
	}

	get running(): boolean {
		return this.#timer !== undefined;
	}

	get component(): StreamingRevealComponent | undefined {
		return this.#component;
	}

	/** Start revealing `text` into `component`, replacing any previous target. */
	begin(component: StreamingRevealComponent, text: string): void {
		this.stop();
		this.#component = component;
		this.#target = text;
		this.#revealed = 0;
		this.#advance();
	}

	/** Grow (or replace) the text being revealed. */
	setTarget(text: string): void {
		if (!this.#component) return;
		this.#target = text;
		// A rewind (retry, resync) must not leave the cursor past the end.
		const total = this.#counter.count(text);
		if (this.#revealed > total) this.#revealed = total;
		this.#advance();
	}

	/**
	 * Reveal everything immediately and stop the timer, leaving the component
	 * showing the whole target. Called before finalizing a run so the sealed
	 * bytes are the complete answer, never a mid-reveal prefix.
	 */
	finish(): void {
		const component = this.#component;
		if (!component) return;
		this.#stopTimer();
		this.#revealed = this.#counter.count(this.#target);
		component.updateContent(this.#target, { transient: true });
		this.#requestRender(component);
	}

	/** Detach without touching the component. */
	stop(): void {
		this.#stopTimer();
		this.#component = undefined;
		this.#target = "";
		this.#revealed = 0;
		this.#counter.reset();
	}

	// -- internals -----------------------------------------------------------

	#advance(): void {
		const component = this.#component;
		if (!component) return;
		if (!this.#getSmoothStreaming()) {
			this.#stopTimer();
			this.#revealed = this.#counter.count(this.#target);
			component.updateContent(this.#target, { transient: true });
			// No timer runs on this path, so nothing else would ever paint the
			// delta: request the component render here or the text stays invisible
			// until some unrelated event forces a frame.
			this.#requestRender(component);
			return;
		}
		this.#render();
		this.#syncTimer();
	}

	#render(): void {
		const component = this.#component;
		if (!component) return;
		// Every controller render is an in-flight streaming snapshot, even when
		// the reveal has momentarily caught up; the finalize path performs the
		// only non-transient render.
		component.updateContent(this.#counter.slice(this.#target, this.#revealed), { transient: true });
	}

	#syncTimer(): void {
		if (!this.#component || this.#revealed >= this.#counter.count(this.#target)) {
			this.#stopTimer();
			return;
		}
		if (this.#timer) return;
		this.#timer = setInterval(() => this.#tick(), STREAMING_REVEAL_FRAME_MS);
		this.#timer.unref?.();
	}

	#stopTimer(): void {
		if (!this.#timer) return;
		clearInterval(this.#timer);
		this.#timer = undefined;
	}

	#tick(): void {
		const component = this.#component;
		if (!component) {
			this.stop();
			return;
		}
		const total = this.#counter.count(this.#target);
		if (this.#revealed >= total) {
			this.#stopTimer();
			return;
		}
		this.#revealed = Math.min(total, this.#revealed + nextStep(total - this.#revealed));
		this.#render();
		this.#requestRender(component);
		if (this.#revealed >= total) this.#stopTimer();
	}
}
