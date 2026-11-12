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
 * terminal history, so an unsealed shelf reports itself unfinalized. The
 * semantic retirement ledger keeps it and everything following it mutable
 * until the controller seals the shelf at a transcript barrier.
 */

import { col } from "@oh-my-pi/pi-tui/native/describe";
import {
	type DescribeContext,
	leafKey,
	type NativeChild,
	type NativeNode,
	type NativeUiEvent,
} from "@oh-my-pi/pi-tui/native/node";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import type { Block, ToolBlock } from "../../store/transcript-model.ts";
import { nativeReadGroup, readGroupKey } from "../../terminal/native-tool.ts";
import { type AccordionState, accordionSettings, resolveAccordionState } from "./accordion.ts";
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
	/** Finished cards the user expanded out of their one-line shelf form. */
	readonly #pinnedOpen = new Set<ToolCardComponent>();
	readonly #cardOptions: ToolCardOptions;

	#sealed = false;
	#version = 0;
	#cachedKey = "";
	#cachedWidth = -1;
	#cached: readonly string[] = [];
	#native: NativeNode | undefined;
	#nativeSignature = "";
	/** Native read groups by their first read's block id, with the inputs they were built from. */
	#readGroups = new Map<string, { key: string; node: NativeNode }>();
	/** Read groups (by first read's block id) the user opened. */
	readonly #openReads = new Set<string>();

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
	 * The expand key, for one card. A card merged into a shelf line opens as a
	 * full, expanded card; an open card toggles expanded ↔ collapsed, and a card
	 * the user had opened out of its shelf line folds back into it.
	 */
	toggle(blockId: string): AccordionState | undefined {
		const card = this.#byBlockId.get(blockId);
		if (!card) return undefined;
		if (card.compact) {
			this.#pinnedOpen.add(card);
			card.expand();
			this.#recompute();
			this.#toggleReadGroup(card, true);
			return "expanded";
		}
		const state = card.toggleAccordion();
		if (state === "collapsed" && this.#pinnedOpen.delete(card)) this.#recompute();
		this.#toggleReadGroup(card, state === "expanded");
		return state;
	}

	/**
	 * Re-apply the global accordion override (Ctrl+T) to every card. `expanded`
	 * also opens merged shelf lines into full cards; `default` merges them again.
	 */
	applyAccordionOverride(): void {
		this.#pinnedOpen.clear();
		this.#openReads.clear();
		for (const card of this.#entries) card.setAccordionState(resolveAccordionState(card.view.kind));
		this.#recompute();
	}

	/**
	 * Freeze the shelf as history: no further entries, no animation, rows become
	 * commit-eligible. Idempotent.
	 */
	seal(): void {
		if (this.#sealed) return;
		this.#sealed = true;
		for (const card of this.#entries) {
			if (card.view.kind !== "subagent" || card.isTranscriptBlockFinalized()) card.dispose();
		}
		this.#version++;
	}

	dispose(): void {
		for (const card of this.#entries) card.dispose();
	}

	// -- FinalizableBlock ----------------------------------------------------

	isTranscriptBlockFinalized(): boolean {
		return (
			this.#sealed &&
			!this.#entries.some(
				(card) => card.view.kind === "subagent" && !card.isTranscriptBlockFinalized(),
			)
		);
	}

	getTranscriptBlockVersion(): number {
		return this.#version + this.#entryVersions();
	}

	// -- render --------------------------------------------------------------

	/**
	 * Each card is its own native `tool` node, except a run of two or more
	 * settled reads, which folds into one `Read N files` node the way omp's
	 * read group does. Cards keep their identity; a group node is rebuilt only
	 * when one of its reads or its open state changes.
	 */
	describe(context?: DescribeContext): NativeNode {
		const runs = this.#readRuns();
		const mediaSupported = context?.supports("media") ?? false;
		const signature = `${mediaSupported}|${this.#entries
			.map((card) => {
				const run = runs.get(card);
				if (!run) return card.block.id;
				return `${card.block.id}@${card.getTranscriptBlockVersion()}${this.#readGroupOpen(run[0]!.block.id) ? "+" : ""}`;
			})
			.join("|")}`;
		if (this.#native && this.#nativeSignature === signature) return this.#native;
		const children: NativeChild[] = [];
		const groups = new Map<string, { key: string; node: NativeNode }>();
		for (const card of this.#entries) {
			const run = runs.get(card);
			if (!run) {
				children.push(card);
				continue;
			}
			if (run[0] !== card) continue;
			const firstId = card.block.id;
			const open = this.#readGroupOpen(firstId);
			const key = `${run.map((read) => `${read.block.id}@${read.getTranscriptBlockVersion()}`).join(",")}|${open}|${mediaSupported}`;
			const cached = this.#readGroups.get(firstId);
			const group =
				cached?.key === key
					? cached
					: {
							key,
							node: nativeReadGroup(
								run.map((read) => ({ block: read.block, view: read.view })),
								open,
								context,
							),
						};
			groups.set(firstId, group);
			children.push(group.node);
		}
		this.#readGroups = groups;
		this.#native = col(children);
		this.#nativeSignature = signature;
		return this.#native;
	}

	/** Tern's disclosure on a read group: open shows each read's content. */
	handleNativeEvent(event: NativeUiEvent): void {
		if (event.type !== "toggle") return;
		const leaf = leafKey(event.key);
		for (const firstId of this.#readGroups.keys()) {
			if (readGroupKey(firstId) !== leaf) continue;
			if (event.collapsed) this.#openReads.delete(firstId);
			else this.#openReads.add(firstId);
			this.#version++;
			this.#cardOptions.requestRender?.(this);
			return;
		}
	}

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
	 * Each card that belongs to a native read group, mapped to its run: two or
	 * more consecutive settled reads. A live read keeps its own card.
	 */
	#readRuns(): Map<ToolCardComponent, ToolCardComponent[]> {
		const runs = new Map<ToolCardComponent, ToolCardComponent[]>();
		let run: ToolCardComponent[] = [];
		const close = () => {
			if (run.length >= 2) for (const card of run) runs.set(card, run);
			run = [];
		};
		for (const card of this.#entries) {
			const state = card.view.state;
			if (card.view.toolName === "read" && (state === "success" || state === "error"))
				run.push(card);
			else close();
		}
		close();
		return runs;
	}

	/** Open or fold the native read group holding `card`, so the expand key reaches it too. */
	#toggleReadGroup(card: ToolCardComponent, open: boolean): void {
		const run = this.#readRuns().get(card);
		if (!run) return;
		const firstId = run[0]!.block.id;
		if (open) this.#openReads.add(firstId);
		else this.#openReads.delete(firstId);
	}

	#readGroupOpen(firstId: string): boolean {
		return this.#openReads.has(firstId) || accordionSettings.override === "expanded";
	}

	/**
	 * A finished entry merges to a single line once the shelf holds a run worth
	 * merging; a still-running entry always keeps its card so its progress is
	 * readable.
	 */
	#recompute(): void {
		const merge =
			this.#entries.length >= SHELF_MERGE_THRESHOLD && accordionSettings.override !== "expanded";
		let changed = false;
		for (const card of this.#entries) {
			const compact = merge && card.isTranscriptBlockFinalized() && !this.#pinnedOpen.has(card);
			if (card.compact !== compact) changed = true;
			card.setCompact(compact);
		}
		// Only a real shape change bumps the version. An update the card dropped
		// (a replayed phase regression) must leave this block byte-identical, and
		// a version bump alone would force the transcript to re-emit its rows.
		if (changed) this.#version++;
	}
}
