/**
 * Tool activity in the transcript — and the seam P3 builds real tool cards on.
 *
 * A tool block is rendered by whatever renderer is registered for its action
 * kind ({@link registerToolBlockRenderer}); anything unregistered falls back to
 * {@link ToolLineComponent}, the one-line placeholder this phase ships. P3
 * registers per-kind cards (bash, edit, read, …) driven by `src/formatters/`
 * against the same {@link ToolBlockComponent} contract, and nothing outside
 * this file needs to change.
 *
 * A tool whose phase is not `completed` is still mutating, so it reports
 * unfinalized: the transcript container keeps it (and everything below it) in
 * the repaintable live region until its result lands.
 */

import { Text } from "@oh-my-pi/pi-tui/components/text";
import { type Component, Container } from "@oh-my-pi/pi-tui/tui";
import type { ToolBlock } from "../../store/transcript-model.ts";
import { getTheme } from "../theme/theme.ts";

export interface ToolBlockComponent extends Component {
	/** Re-render from the block's current state (phase, ok, message). */
	update(block: ToolBlock): void;
}

export type ToolBlockRenderer = (block: ToolBlock) => ToolBlockComponent;

const renderers = new Map<string, ToolBlockRenderer>();

/** Register a renderer for an action kind. Returns an unregister function. */
export function registerToolBlockRenderer(kind: string, renderer: ToolBlockRenderer): () => void {
	renderers.set(kind, renderer);
	return () => {
		if (renderers.get(kind) === renderer) renderers.delete(kind);
	};
}

export function resolveToolBlockRenderer(kind: string): ToolBlockRenderer | undefined {
	return renderers.get(kind);
}

/** Test hook: drop every registration. */
export function clearToolBlockRenderers(): void {
	renderers.clear();
}

export function createToolBlockComponent(block: ToolBlock): ToolBlockComponent {
	const renderer = renderers.get(String(block.toolKind));
	return renderer ? renderer(block) : new ToolLineComponent(block);
}

export class ToolLineComponent extends Container implements ToolBlockComponent {
	readonly #line = new Text("", 1, 0);
	readonly #detail = new Text("", 1, 0);
	#finalized = false;
	#version = 0;

	constructor(block: ToolBlock) {
		super();
		this.addChild(this.#line);
		this.addChild(this.#detail);
		this.update(block);
	}

	update(block: ToolBlock): void {
		const theme = getTheme();
		const done = block.phase === "completed";
		const slot = !done ? "toolRunning" : block.ok === false ? "toolError" : "toolSuccess";
		const glyph = !done ? "…" : block.ok === false ? "✗" : "✓";
		// Text word-wraps at the render width; nothing here measures with .length.
		this.#line.setText(
			`${theme.fg(slot, `${glyph} ${block.title}`)}${theme.fg("dim", ` (${block.toolKind})`)}`,
		);
		const message = done ? block.message?.trim() : undefined;
		this.#detail.setText(message ? theme.fg("toolDetail", `  ${message}`) : "");
		this.#finalized = done;
		this.#version++;
	}

	isTranscriptBlockFinalized(): boolean {
		return this.#finalized;
	}

	getTranscriptBlockVersion(): number {
		return this.#version;
	}
}
