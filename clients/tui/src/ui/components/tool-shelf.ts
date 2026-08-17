/**
 * The tool shelf: consecutive tool calls, merged.
 *
 * A run of tool activity with nothing else between it — five reads, a grep, a
 * bash — is scaffolding, not content. The shelf owns such a run and renders
 * each finished member as **one line** (icon · title · summary) once there is
 * more than one of them, so a burst of ten tools costs ten rows instead of
 * fifty. A run of exactly one keeps its full card: a lone `bash` is usually the
 * thing the user actually wanted to read.
 *
 * ## Barriers
 *
 * The shelf accepts tool blocks until a barrier closes it — any non-tool block
 * (an assistant reply, a notice, an approval) or the end of the run. The
 * {@link EventController} owns that decision and calls {@link seal}.
 *
 * ## Why sealing matters
 *
 * The shelf's *shape* changes as it grows: entry one is a full card until entry
 * two arrives, at which point both collapse to single lines. Rewriting rows
 * that already reached native scrollback would strand stale copies in immutable
 * terminal history, so an unsealed shelf reports itself unfinalized **and**
 * pins the live region (`isNativeScrollbackLiveRegionPinned`), keeping every row
 * off the tape until the shape is final. This is the same displaceable-snapshot
 * contract omp's task blocks use; the transcript container's belt-and-braces
 * `sealCommittedSnapshot` pass seals us anyway if a row ever does commit.
 */

import type { Component } from "@oh-my-pi/pi-tui/tui";
import type { Block, ToolBlock } from "../../store/transcript-model.ts";
import { ToolCardComponent, type ToolCardOptions } from "./tool-card.ts";

/** Entries a shelf needs before it starts merging them into single lines. */
export const SHELF_MERGE_THRESHOLD = 2;

/**
 * Group a block list the way the shelf does: maximal runs of consecutive tool
 * blocks. Pure, and exported for the gallery and for tests — the component's
 * own grouping is the incremental version of this.
 */
export function planToolShelves(blocks: readonly Block[]): ToolBlock[][] {
	const groups: ToolBlock[][] = [];
	let current: ToolBlock[] | undefined;
	for (const block of blocks) {
		if (block.kind !== "tool") {
			current = undefined;
			continue;
		}
		if (!current) {
			current = [];
			groups.push(current);
		}
		current.push(block);
	}
	return groups;
}

export class ToolShelfComponent implements Component {
	readonly #entries: ToolCardComponent[] = [];
	readonly #byBlockId = new Map<string, ToolCardComponent>();
	readonly #cardOptions: ToolCardOptions;

	#sealed = false;
	#version = 0;
	#cachedKey = "";
	#cachedWidth = -1;
	#cached: readonly string[] = [];

	constructor(cardOptions: ToolCardOptions = {}) {
		// Cards live inside the shelf, not directly under a root child, so their
		// animation ticks must name the shelf as the render target — that is the
		// component the TUI can locate in the tree.
		const requestRender = cardOptions.requestRender;
		this.#cardOptions = requestRender
			? { ...cardOptions, requestRender: () => requestRender(this) }
			: cardOptions;
	}

	get size(): number {
		return this.#entries.length;
	}

	get sealed(): boolean {
		return this.#sealed;
	}

	get cards(): readonly ToolCardComponent[] {
		return this.#entries;
	}

	/** Whether a further tool block may join. False once a barrier sealed it. */
	get open(): boolean {
		return !this.#sealed;
	}

	has(blockId: string): boolean {
		return this.#byBlockId.has(blockId);
	}

	cardFor(blockId: string): ToolCardComponent | undefined {
		return this.#byBlockId.get(blockId);
	}

	/** Add a tool block. Returns its card, or undefined if the shelf is sealed. */
	add(block: ToolBlock): ToolCardComponent | undefined {
		if (this.#sealed) return undefined;
		const existing = this.#byBlockId.get(block.id);
		if (existing) {
			this.update(block);
			return existing;
		}
		const card = new ToolCardComponent(block, this.#cardOptions);
		this.#entries.push(card);
		this.#byBlockId.set(block.id, card);
		this.#recompute();
		return card;
	}

	update(block: ToolBlock): void {
		const card = this.#byBlockId.get(block.id);
		if (!card) return;
		card.update(block);
		this.#recompute();
	}

	/**
	 * Freeze the shelf as history: no further entries, no animation, rows become
	 * commit-eligible. Idempotent — the container may call it too.
	 */
	seal(): void {
		if (this.#sealed) return;
		this.#sealed = true;
		for (const card of this.#entries) card.dispose();
		this.#version++;
	}

	dispose(): void {
		for (const card of this.#entries) card.dispose();
	}

	// -- FinalizableBlock ----------------------------------------------------

	isTranscriptBlockFinalized(): boolean {
		return this.#sealed;
	}

	isDisplaceableBlock(): boolean {
		return !this.#sealed;
	}

	/**
	 * Keep an unsealed shelf's rows off the tape: they re-shape when the run
	 * grows, and committed rows are immutable.
	 */
	isNativeScrollbackLiveRegionPinned(): boolean {
		return !this.#sealed;
	}

	getTranscriptBlockVersion(): number {
		return this.#version + this.#entryVersions();
	}

	// -- render --------------------------------------------------------------

	render(width: number): readonly string[] {
		const key = `${this.#version}|${this.#entryVersions()}|${this.#entries.length}`;
		if (this.#cachedWidth === width && this.#cachedKey === key) return this.#cached;
		this.#cachedWidth = width;
		this.#cachedKey = key;
		const rows: string[] = [];
		for (const card of this.#entries) {
			for (const row of card.render(width)) rows.push(row);
		}
		this.#cached = rows;
		return rows;
	}

	invalidate(): void {
		this.#cachedKey = "";
		this.#cachedWidth = -1;
		for (const card of this.#entries) card.invalidate?.();
	}

	// -- internals -----------------------------------------------------------

	#entryVersions(): number {
		let total = 0;
		for (const card of this.#entries) total += card.getTranscriptBlockVersion();
		return total;
	}

	/**
	 * A finished entry merges to a single line once the shelf holds a run worth
	 * merging; a still-running entry always keeps its card so its progress is
	 * readable.
	 */
	#recompute(): void {
		const merge = this.#entries.length >= SHELF_MERGE_THRESHOLD;
		let changed = false;
		for (const card of this.#entries) {
			const compact = merge && card.isTranscriptBlockFinalized();
			if (card.compact !== compact) changed = true;
			card.setCompact(compact);
		}
		// Only a real shape change bumps the version. An update the card dropped
		// (a replayed phase regression) must leave this block byte-identical, and
		// a version bump alone would force the transcript to re-emit its rows.
		if (changed) this.#version++;
	}
}
