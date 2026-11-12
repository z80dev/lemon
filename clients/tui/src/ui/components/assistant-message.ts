/**
 * A streaming assistant reply.
 *
 * Stable Markdown source boundaries, rather than physical row offsets, identify
 * the streamed head eligible for history. Each publication must remain a byte
 * prefix at every width; pi-tui retires only publications above the live tail.
 */

import {
	hasTranscriptActions,
	runTranscriptAction,
} from "@oh-my-pi/pi-tui/chat/transcript-actions";
import {
	isRowPrefix,
	type TranscriptStableRow,
	trimBlankEdges,
} from "@oh-my-pi/pi-tui/chrome/transcript-container";
import { Markdown } from "@oh-my-pi/pi-tui/components/markdown";
import { Text } from "@oh-my-pi/pi-tui/components/text";
import { col, node, span, text } from "@oh-my-pi/pi-tui/native/describe";
import type { NativeChild, NativeNode, NativeUiEvent } from "@oh-my-pi/pi-tui/native/node";
import { iconButton } from "@oh-my-pi/pi-tui/native/overlay";
import { plainText } from "@oh-my-pi/pi-tui/native/spans";
import { formatTurnUsage } from "@oh-my-pi/pi-tui/overlays/usage-row";
import { Container } from "@oh-my-pi/pi-tui/tui";
import { formatDuration } from "@oh-my-pi/pi-utils";
import type { TurnSummary } from "../../store/transcript-model.ts";
import { TranscriptMarks, type TranscriptPhase } from "../../terminal/marks.ts";
import { getTheme } from "../theme/theme.ts";
import { getMarkdownTheme } from "../theme/tui-adapters.ts";
import { describeErrorFrame } from "./native-chrome.ts";
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
	/** The daemon's completion report; native terminals show it as the turn footer. */
	turn?: TurnSummary;
}

export class AssistantMessageComponent extends Container {
	readonly #markdown: Markdown;
	/** Holds the post-run error line, if any. Empty renders zero rows. */
	readonly #footer = new Container();
	readonly #clamp = new WidthClamp();
	readonly #marks = new TranscriptMarks();
	#phase: TranscriptPhase = "running";
	#native: NativeNode | undefined;
	#nativeVersion = -1;
	#nativeBody: { text: string; stream: boolean; node: NativeNode } | undefined;

	#text = "";
	/** The reply without the row renderer's interrupted marker. */
	#answer = "";
	#finalized = false;
	#transient = true;
	#version = 0;
	#outcome: { interrupted: boolean; error?: string; turn?: TurnSummary } | undefined;
	readonly transcriptBlockMode = "appendOnly";
	readonly #prefixMarkdown: Markdown;
	readonly #prefixClamp = new WidthClamp();
	readonly #prefixMarks = new TranscriptMarks();
	#stableText = "";
	#stableEnds: number[] = [];
	#stableRows: TranscriptStableRow[] = [];
	#stableRender: { width: number; count: number; rows: readonly string[] } | undefined;

	constructor(text = "") {
		super();
		const theme = getTheme();
		this.#markdown = new Markdown(text, 1, 0, getMarkdownTheme(), {
			color: (value) => theme.fg("assistantText", value),
		});
		this.#prefixMarkdown = new Markdown("", 1, 0, getMarkdownTheme(), {
			color: (value) => theme.fg("assistantText", value),
		});
		// Streaming renders bypass the markdown module LRU and expose a frozen
		// prefix; the finalize render flips this off so the final bytes are the
		// cached, fully highlighted ones.
		this.#markdown.transientRenderCache = true;
		this.#text = text;
		this.#answer = text;
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
		this.#answer = fullText;
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
		this.#answer = options.interrupted
			? body.slice(0, body.length - INTERRUPTED_SUFFIX.length)
			: body;
		this.#finalized = true;
		this.#phase = options.ok === false || options.interrupted ? "error" : "success";
		this.#outcome = {
			interrupted: options.interrupted === true,
			...(options.ok === false ? { error: options.error ?? "run failed" } : {}),
			...(options.turn ? { turn: options.turn } : {}),
		};
		this.#footer.clear();
		if (options.ok === false && options.error) {
			this.#footer.addChild(new Text(theme.fg("error", `Error: ${options.error}`), 1, 0));
			this.#version++;
		}
	}

	/**
	 * omp's turn: the reply as one `md` node (`stream` while it arrives, so
	 * deltas reach the terminal as text appends), then how it ended — an
	 * interrupted label, a failed-run frame — and the turn footer (Copy ·
	 * duration · tokens · cost) once the daemon reported completion.
	 */
	override describe(): NativeNode {
		if (this.#nativeVersion === this.#version && this.#native) return this.#native;
		// These semantic roles are Tern's chat/transcript contract, shared
		// by Carly's wait/transcript API and native reply navigation.
		const children: NativeChild[] = [];
		const answer = this.#answer.trim();
		if (answer) children.push(this.#describeBody(answer));
		const outcome = this.#outcome;
		if (outcome?.interrupted) {
			children.push(
				text([span("Interrupted", "error")], {
					wrap: "word",
					key: "abort",
					role: "omp.assistant.abort",
				}),
			);
		}
		if (outcome?.error !== undefined) {
			// Lemon has no retry command, so omp's Retry control is not offered.
			children.push(
				describeErrorFrame("Run failed", outcome.error, [
					{ act: "copy-error", label: "Copy error", title: "Copy the error message" },
					{
						act: "switch-model",
						label: "Switch model",
						title: "Pick another model for this session",
						keys: "ctrl+o",
					},
				]),
			);
		}
		// Only the run's last segment carries the daemon's completion report;
		// earlier segments of the same turn get no footer, like omp's.
		const footer = outcome?.turn ? describeTurnFooter(outcome.turn, answer.length > 0) : undefined;
		if (footer) children.push(footer);
		this.#native = col(children, { role: "omp.assistant" });
		this.#nativeVersion = this.#version;
		return this.#native;
	}

	/** The footer's Copy and the failed-run frame's actions: the host's clipboard and model picker. */
	handleNativeEvent(event: NativeUiEvent): void {
		if (event.type !== "action") return;
		if (event.act === "copy-answer" && this.#answer.trim()) {
			runTranscriptAction({ act: "copy", text: this.#answer.trim() });
		} else if (event.act === "copy-error" && this.#outcome?.error) {
			runTranscriptAction({ act: "copy", text: this.#outcome.error });
		} else if (event.act === "switch-model") {
			runTranscriptAction({ act: "switch-model" });
		}
	}

	#describeBody(answer: string): NativeNode {
		const stream = !this.#finalized && this.#transient;
		const cached = this.#nativeBody;
		if (cached?.text === answer && cached.stream === stream) return cached.node;
		// Model text; escape bytes are the terminal's to style, not ours.
		const source = answer.includes("\x1b") ? plainText(answer) : answer;
		const body = node(
			"md",
			stream ? { text: source, stream: true } : { text: source },
			undefined,
			"text",
		);
		this.#nativeBody = { text: answer, stream, node: body };
		return body;
	}

	override render(width: number): readonly string[] {
		// Markdown keeps its horizontal padding at any width, so very narrow
		// renders would otherwise emit rows wider than requested.
		const rows = this.#marks.apply(this.#clamp.apply(super.render(width), width), this.#phase);
		if (!this.#finalized && this.#transient) {
			const text = this.#markdown.getLastRenderStableText();
			if (text.length > this.#stableText.length && text.startsWith(this.#stableText)) {
				const previous = this.renderTranscriptStableRows(this.#stableEnds.length, width);
				this.#prefixMarkdown.setText(text);
				const prefix = trimBlankEdges(
					this.#prefixMarks.apply(
						this.#prefixClamp.apply(this.#prefixMarkdown.render(width), width),
						"running",
					),
				);
				// Keep the final row mutable: finalization can attach OSC 133 D.
				if (
					prefix.length > previous.length &&
					prefix.length < trimBlankEdges(rows).length &&
					isRowPrefix(previous, prefix) &&
					isRowPrefix(prefix, trimBlankEdges(rows))
				) {
					this.#stableText = text;
					this.#stableEnds.push(text.length);
					this.#stableRows.push({ key: `text:${text.length}` });
					this.#stableRender = { width, count: this.#stableEnds.length, rows: prefix };
				}
			}
		}
		return rows;
	}

	override invalidate(): void {
		this.#clamp.reset();
		this.#prefixClamp.reset();
		this.#prefixMarkdown.invalidate();
		this.#stableRender = undefined;
		super.invalidate();
	}

	// -- FinalizableBlock ----------------------------------------------------

	isTranscriptBlockFinalized(): boolean {
		return this.#finalized;
	}

	getTranscriptBlockVersion(): number {
		return this.#version;
	}

	getTranscriptStableRows(): readonly TranscriptStableRow[] {
		return this.#stableRows;
	}

	renderTranscriptStableRows(count: number, width: number): readonly string[] {
		const end = this.#stableEnds[Math.min(Math.trunc(count), this.#stableEnds.length) - 1];
		if (end === undefined) return [];
		if (this.#stableRender?.width === width && this.#stableRender.count === count) {
			return this.#stableRender.rows;
		}
		this.#prefixMarkdown.setText(this.#stableText.slice(0, end));
		const rows = trimBlankEdges(
			this.#prefixMarks.apply(
				this.#prefixClamp.apply(this.#prefixMarkdown.render(width), width),
				"running",
			),
		);
		this.#stableRender = { width, count, rows };
		return rows;
	}

	resetTranscriptStableRows(): void {
		this.#stableText = "";
		this.#stableEnds = [];
		this.#stableRows = [];
		this.#stableRender = undefined;
	}
}

/**
 * omp's `omp.turn.usage` line under a finished turn: Copy (when there is an
 * answer to copy) · `12.4s · 19K tok · $0.02 this turn`. Parts the daemon did
 * not report are left out rather than shown as zero.
 */
function describeTurnFooter(turn: TurnSummary, answered: boolean): NativeNode | undefined {
	const line: NativeNode[] = [];
	if (answered && hasTranscriptActions()) {
		const copy = iconButton("copy", "copy-answer", "Copy answer", { key: "copy" });
		copy.p!.role = "omp.turn.copy";
		line.push(copy);
	}
	const usage = turnUsageText(turn);
	if (usage) {
		if (line.length > 0) line.push(node("text", { text: "·" }, undefined, "dot"));
		line.push(node("text", { text: usage.text }, undefined, "text"));
	}
	if (line.length === 0) return undefined;
	return node(
		"row",
		{
			role: "omp.turn.usage",
			gap: "xs",
			align: "center",
			...(usage ? { title: usage.title } : {}),
		},
		line,
		"turn-usage",
	);
}

function turnUsageText(turn: TurnSummary): { text: string; title: string } | undefined {
	const elapsedMs =
		turn.durationMs !== undefined && turn.durationMs > 0 ? turn.durationMs : undefined;
	const usage = turn.usage;
	const input = count(usage?.inputTokens) + count(usage?.cacheWriteTokens);
	const output = count(usage?.outputTokens);
	const cost = count(usage?.costUsd);
	let summary: { text: string; title: string } | undefined;
	if (input + output > 0 || cost > 0) {
		summary = formatTurnUsage({ elapsedMs, input, output, cost });
	} else if (elapsedMs !== undefined) {
		const time = formatDuration(elapsedMs);
		summary = { text: `${time} this turn`, title: `This turn: ${time}` };
	}
	if (!summary) return undefined;
	return turn.model ? { text: summary.text, title: `${summary.title} · ${turn.model}` } : summary;
}

function count(value: number | null | undefined): number {
	return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : 0;
}
