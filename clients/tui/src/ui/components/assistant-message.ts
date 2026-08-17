/**
 * A streaming assistant reply.
 *
 * Skeleton cribbed from omp's `AssistantMessageComponent`, reduced to what the
 * lemon protocol actually carries: one text stream per run (no thinking blocks,
 * no citations, no inline images). What survives verbatim in spirit is the
 * FinalizableBlock protocol the {@link TranscriptContainer} reads:
 *
 *   - `isTranscriptBlockFinalized()` — false while streaming, so the container
 *     keeps the block inside the repaintable live region;
 *   - `getTranscriptBlockVersion()` — bumped by every mutation, including the
 *     post-finalize ones (a late error line), so the container's committed-row
 *     replay bypass cannot serve stale bytes;
 *   - `getTranscriptBlockSettledRows()` — the rendered *frozen token prefix* of
 *     the streaming markdown, and nothing else. Those rows are byte-provably
 *     final at this width, which is what lets a long reply's scrolled-off head
 *     reach native scrollback mid-stream. Under-declaring only delays a commit;
 *     over-declaring strands stale bytes in terminal history forever.
 */

import { Markdown } from "@oh-my-pi/pi-tui/components/markdown";
import { Text } from "@oh-my-pi/pi-tui/components/text";
import { Container } from "@oh-my-pi/pi-tui/tui";
import { getTheme } from "../theme/theme.ts";
import { getMarkdownTheme } from "../theme/tui-adapters.ts";
import { WidthClamp } from "./width-safe.ts";

/** Appended to the visible text when the user aborted a run mid-stream. */
export const INTERRUPTED_SUFFIX = "*[interrupted]*";

export interface AssistantFinalizeOptions {
	/** False renders the error line and marks the block failed. */
	ok?: boolean;
	/** Keeps the partial text and appends {@link INTERRUPTED_SUFFIX}. */
	interrupted?: boolean;
	/** Shown under the body when the run failed. */
	error?: string;
}

export class AssistantMessageComponent extends Container {
	readonly #markdown: Markdown;
	/** Holds the post-run error line, if any. Empty renders zero rows. */
	readonly #footer = new Container();
	readonly #clamp = new WidthClamp();

	#text = "";
	#finalized = false;
	#transient = true;
	#version = 0;

	constructor(text = "") {
		super();
		const theme = getTheme();
		this.#markdown = new Markdown(text, 1, 0, getMarkdownTheme(), {
			color: (value) => theme.fg("assistantText", value),
		});
		// Streaming renders bypass the markdown module LRU and expose a frozen
		// prefix; the finalize render flips this off so the final bytes are the
		// cached, fully highlighted ones.
		this.#markdown.transientRenderCache = true;
		this.#text = text;
		this.addChild(this.#markdown);
		this.addChild(this.#footer);
	}

	get text(): string {
		return this.#text;
	}

	/**
	 * Replace the visible text. `transient` marks an in-flight streaming
	 * snapshot (the default while unfinalized); the finalize path is the only
	 * non-transient render.
	 */
	updateContent(fullText: string, options: { transient?: boolean } = {}): void {
		const transient = options.transient ?? !this.#finalized;
		this.#version++;
		this.#text = fullText;
		if (this.#transient !== transient) {
			this.#transient = transient;
			this.#markdown.transientRenderCache = transient;
		}
		this.#markdown.setText(fullText);
	}

	/**
	 * Seal the block: no further streaming, rows become commit-eligible as a
	 * whole. Keeps whatever text was revealed — an interrupted run's partial
	 * answer is history too, just marked as such.
	 */
	finalize(options: AssistantFinalizeOptions = {}): void {
		const theme = getTheme();
		// The marker is markdown source, not pre-styled text: the Markdown child
		// renders the emphasis itself, the same way it does for the reply body.
		const body = options.interrupted
			? `${this.#text}${this.#text.length === 0 || this.#text.endsWith("\n") ? "" : "\n\n"}${INTERRUPTED_SUFFIX}`
			: this.#text;
		this.updateContent(body, { transient: false });
		this.#finalized = true;
		this.#footer.clear();
		if (options.ok === false && options.error) {
			this.#footer.addChild(new Text(theme.fg("error", `Error: ${options.error}`), 1, 0));
			this.#version++;
		}
	}

	override render(width: number): readonly string[] {
		// Markdown keeps its horizontal padding at any width, so very narrow
		// renders would otherwise emit rows wider than requested.
		return this.#clamp.apply(super.render(width), width);
	}

	override invalidate(): void {
		this.#clamp.reset();
		super.invalidate();
	}

	// -- FinalizableBlock ----------------------------------------------------

	isTranscriptBlockFinalized(): boolean {
		return this.#finalized;
	}

	getTranscriptBlockVersion(): number {
		return this.#version;
	}

	getTranscriptBlockSettledRows(): number {
		// A finalized block commits wholly through the finalized-block path; a
		// non-transient render exposes no frozen prefix to reason about.
		if (this.#finalized || !this.#transient) return 0;
		// The markdown is child 0 with paddingY 0, so its settled row count is
		// already in this component's raw render coordinates. Anything below it
		// (the error footer) can only appear after finalize.
		return this.#markdown.getLastRenderSettledRows();
	}
}
