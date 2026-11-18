/**
 * The model's thinking, as its own dimmed transcript block.
 *
 * A header line (`✻ thinking`) over an {@link AccordionComponent} that starts
 * collapsed to the first line of the thought — reasoning is context, not the
 * answer. The expand key (see `input-controller.ts`) opens it to the full text,
 * word-wrapped at the render width.
 *
 * The block is live (unfinalized) while the model is still thinking, so its
 * rows stay repaintable; once the reasoning phase completes — or the run ends,
 * which {@link SessionStore.finalizeRun} treats as completing it — its bytes
 * may reach native scrollback. An expand toggle after that still repaints
 * whatever is inside the window (the container re-renders on a version bump).
 */

import { elapsed, node, span } from "@oh-my-pi/pi-tui/native/describe";
import type { NativeNode, NativeUiEvent } from "@oh-my-pi/pi-tui/native/node";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth } from "@oh-my-pi/pi-tui/utils";
import { displayMarkdown, displayText } from "../../formatters/base.ts";
import type { ReasoningBlock } from "../../store/transcript-model.ts";
import { getTheme } from "../theme/theme.ts";
import { AccordionComponent, type AccordionState, resolveAccordionState } from "./accordion.ts";

export class ReasoningComponent implements Component {
	readonly #accordion: AccordionComponent;
	#block: ReasoningBlock;
	#text = "";
	#live = true;
	/**
	 * Client-observed thinking time. Only a block seen streaming has one; a
	 * block born finished (history, a late join) never claims a duration.
	 */
	#clock: { start: number; end?: number } | undefined;
	/** The terminal's own fold, mirrored back; a keyboard toggle hands control back to the accordion. */
	#nativeCollapsed: boolean | undefined;
	#nativeBody: { text: string; stream: boolean; node: NativeNode } | undefined;
	#native: NativeNode | undefined;
	#nativeKey = "";

	#version = 0;
	#cachedVersion = -1;
	#cachedAccordion = -1;
	#cachedWidth = -1;
	#cached: readonly string[] = [];

	constructor(block: ReasoningBlock, options: { accordion?: AccordionState } = {}) {
		this.#block = block;
		this.#accordion = new AccordionComponent(
			options.accordion ?? resolveAccordionState("reasoning"),
			{ indent: 2, wrap: true, moreHint: (hidden) => `+${hidden} more lines` },
		);
		if (block.phase !== "completed") this.#clock = { start: Date.now() };
		this.update(block);
	}

	get block(): ReasoningBlock {
		return this.#block;
	}

	get accordion(): AccordionComponent {
		return this.#accordion;
	}

	/** Re-derive from the block's current text and phase. No-op when neither moved. */
	update(block: ReasoningBlock): void {
		this.#block = block;
		const live = block.phase !== "completed";
		if (block.text === this.#text && live === this.#live) return;
		if (this.#live && !live && this.#clock && this.#clock.end === undefined) {
			this.#clock.end = Date.now();
		}
		this.#text = block.text;
		this.#live = live;
		this.#applyText();
	}

	toggleAccordion(): AccordionState {
		this.#nativeCollapsed = undefined;
		return this.#accordion.toggle();
	}

	setAccordionState(state: AccordionState): void {
		this.#nativeCollapsed = undefined;
		this.#accordion.setState(state);
	}

	// -- FinalizableBlock ----------------------------------------------------

	isTranscriptBlockFinalized(): boolean {
		return !this.#live;
	}

	getTranscriptBlockVersion(): number {
		return this.#version + this.#accordion.version;
	}

	// -- render --------------------------------------------------------------

	/**
	 * omp's thinking section: while the model thinks, `omp.thinking.live` with
	 * the starburst spinner (`omp.thinking.spin`), "Thinking…" and a terminal-
	 * clocked timer, open so the tail streams under its fade; once done,
	 * `omp.thinking` headed "Thought for 12s", folded unless expanded. Hidden
	 * keeps only the folded head.
	 */
	describe(): NativeNode {
		const state = this.#accordion.state;
		const collapsed =
			this.#nativeCollapsed ?? (this.#live ? state === "hidden" : state !== "expanded");
		const key = `${this.getTranscriptBlockVersion()}|${collapsed}`;
		if (this.#native && this.#nativeKey === key) return this.#native;
		const clock = this.#clock;
		const head = this.#live
			? node(
					"row",
					{ gap: "sm" },
					[
						node("spinner", { style: "starburst", role: "omp.thinking.spin" }, undefined, "spin"),
						node("text", { spans: [span("Thinking…", "muted")] }, undefined, "label"),
						{ ...elapsed(Date.now() - (clock?.start ?? Date.now())), key: "elapsed" },
					],
					"head",
				)
			: node("text", { spans: [span(thoughtLabel(clock), "muted")] }, undefined, "head");
		const body = state === "hidden" ? undefined : this.#describeBody();
		const took = clock?.end === undefined ? undefined : Math.max(0, clock.end - clock.start);
		this.#native = node(
			"section",
			{
				role: this.#live ? "omp.thinking.live" : "omp.thinking",
				collapsible: true,
				collapsed,
				...(took !== undefined ? { took } : {}),
			},
			body ? [head, body] : [head],
		);
		this.#nativeKey = key;
		return this.#native;
	}

	/** The terminal folded or opened the section. */
	handleNativeEvent(event: NativeUiEvent): void {
		if (event.type !== "toggle" || event.key !== "") return;
		this.#nativeCollapsed = event.collapsed;
	}

	#describeBody(): NativeNode | undefined {
		const source = this.#text.trim();
		if (!source) return undefined;
		const stream = this.#live;
		const cached = this.#nativeBody;
		if (cached?.text === source && cached.stream === stream) return cached.node;
		// Tern renders this as Markdown, entities included.
		const plain = displayMarkdown(source);
		const body = node(
			"md",
			stream ? { text: plain, stream: true } : { text: plain },
			undefined,
			"body",
		);
		this.#nativeBody = { text: source, stream, node: body };
		return body;
	}

	render(width: number): readonly string[] {
		if (
			this.#cachedVersion === this.#version &&
			this.#cachedAccordion === this.#accordion.version &&
			this.#cachedWidth === width
		) {
			return this.#cached;
		}
		this.#cachedVersion = this.#version;
		this.#cachedAccordion = this.#accordion.version;
		this.#cachedWidth = width;
		const theme = getTheme();
		const glyph = theme.getSymbolPreset() === "ascii" ? "*" : "✻";
		const label = this.#live ? "thinking…" : "thinking";
		const rows = [truncateToWidth(theme.fg("dim", `${glyph} ${label}`), width)];
		for (const row of this.#accordion.render(width)) rows.push(row);
		this.#cached = rows;
		return rows;
	}

	/** Theme change: the body lines carry baked-in colour, so restyle them. */
	invalidate(): void {
		this.#cachedVersion = -1;
		this.#applyText();
	}

	#applyText(): void {
		const theme = getTheme();
		const style = (line: string) => theme.fg("dim", theme.italic(line));
		const text = displayText(this.#text.trim());
		this.#accordion.setLines(text.length > 0 ? text.split(/\r?\n/).map(style) : []);
		const summary = text.split(/\r?\n/, 1)[0] ?? "";
		this.#accordion.setSummary(summary.length > 0 ? style(summary) : "");
		this.#version++;
	}
}

/** "Thought for 12s" when the thinking was watched start to finish, else "Thought". */
function thoughtLabel(clock: { start: number; end?: number } | undefined): string {
	if (clock?.end === undefined) return "Thought";
	const seconds = Math.max(1, Math.round((clock.end - clock.start) / 1000));
	return seconds < 60
		? `Thought for ${seconds}s`
		: `Thought for ${Math.floor(seconds / 60)}m${seconds % 60}s`;
}
