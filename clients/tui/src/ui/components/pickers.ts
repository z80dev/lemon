/**
 * The generic picker overlay: a title, a type-to-filter line, a fuzzy-filtered
 * {@link SelectList}, and a hint footer inside a box.
 *
 * Two rules make it safe to open over a live transcript:
 *   - it never touches the editor, so the draft survives being interrupted by a
 *     picker (the selector controller restores focus on close);
 *   - it never mutates transcript state — a picker reports a choice through its
 *     callback and nothing else.
 *
 * Rendering follows the pi-tui contract: rows are recomputed only when an input
 * changed, and the same array reference is returned otherwise.
 */

import { type SelectItem, SelectList } from "@oh-my-pi/pi-tui/components/select-list";
import { fuzzyRank } from "@oh-my-pi/pi-tui/fuzzy";
import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth, visibleWidth } from "@oh-my-pi/pi-tui/utils";
import { getTheme } from "../theme/theme.ts";
import { getSelectListTheme } from "../theme/tui-adapters.ts";

export interface PickerItem extends SelectItem {}

export interface PickerOptions {
	title: string;
	items: PickerItem[];
	/** Hint line under the list. */
	footer?: string;
	/** Rows of list body; the overlay is sized around this. */
	maxVisible?: number;
	/** Prefilled filter text. */
	filter?: string;
	onSelect: (item: PickerItem) => void;
	onCancel?: () => void;
	/**
	 * Keys the host wants first refusal on (the model picker's global-persist
	 * toggle, a back step out of a second stage). Return true to consume.
	 */
	onKey?: (data: string) => boolean;
}

/**
 * Rank `items` against `query`. Empty queries keep the original order, which is
 * the caller's chosen ordering (recency, relevance) and must not be shuffled.
 */
export function filterItems(items: readonly PickerItem[], query: string): PickerItem[] {
	const trimmed = query.trim();
	if (trimmed.length === 0) return [...items];
	return fuzzyRank(
		[...items],
		trimmed,
		(item) => `${item.label} ${item.value} ${item.description ?? ""}`,
	).map((entry) => entry.item);
}

export class PickerOverlay implements Component {
	readonly #options: PickerOptions;
	#filter: string;
	#filtered: PickerItem[];
	#list: SelectList;
	#maxVisible: number;

	#cachedRows: string[] | undefined;
	#cachedWidth = -1;
	#revision = 0;
	#cachedRevision = -1;

	constructor(options: PickerOptions) {
		this.#options = options;
		this.#filter = options.filter ?? "";
		this.#maxVisible = options.maxVisible ?? 12;
		this.#filtered = filterItems(options.items, this.#filter);
		this.#list = this.#buildList();
	}

	get filter(): string {
		return this.#filter;
	}

	get items(): readonly PickerItem[] {
		return this.#filtered;
	}

	get selected(): PickerItem | undefined {
		return (this.#list.getSelectedItem() as PickerItem | null) ?? undefined;
	}

	setFilter(filter: string): void {
		if (filter === this.#filter) return;
		this.#filter = filter;
		this.#filtered = filterItems(this.#options.items, filter);
		this.#list = this.#buildList();
		this.#invalidateCache();
	}

	/** Swap the item set (a second picker stage) and reset the filter. */
	setItems(items: PickerItem[], filter = ""): void {
		this.#options.items = items;
		this.#filter = filter;
		this.#filtered = filterItems(items, filter);
		this.#list = this.#buildList();
		this.#invalidateCache();
	}

	#buildList(): SelectList {
		const list = new SelectList(this.#filtered, this.#maxVisible, getSelectListTheme(), {
			overflowSearch: false,
		});
		list.onSelect = (item) => this.#options.onSelect(item as PickerItem);
		list.onCancel = () => this.#options.onCancel?.();
		return list;
	}

	#invalidateCache(): void {
		this.#revision += 1;
		this.#cachedRows = undefined;
	}

	invalidate(): void {
		this.#list.invalidate();
		this.#invalidateCache();
	}

	handleInput(data: string): void {
		if (this.#options.onKey?.(data)) {
			this.#invalidateCache();
			return;
		}
		if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) {
			this.#options.onCancel?.();
			return;
		}
		if (matchesKey(data, "enter")) {
			const item = this.selected;
			if (item) this.#options.onSelect(item);
			return;
		}
		if (matchesKey(data, "backspace")) {
			this.setFilter(this.#filter.slice(0, -1));
			return;
		}
		if (matchesKey(data, "ctrl+u")) {
			this.setFilter("");
			return;
		}
		if (isPrintable(data)) {
			this.setFilter(this.#filter + data);
			return;
		}
		// Navigation (arrows, page keys, ctrl+n/p) belongs to the list.
		this.#list.handleInput(data);
		this.#invalidateCache();
	}

	render(width: number): readonly string[] {
		if (
			this.#cachedRows &&
			this.#cachedWidth === width &&
			this.#cachedRevision === this.#revision
		) {
			return this.#cachedRows;
		}
		const theme = getTheme();
		const box = theme.boxRound;
		const inner = Math.max(4, width - 4);
		const rows: string[] = [];

		const line = (content: string, styled?: string) => {
			const visible = visibleWidth(content);
			const pad = " ".repeat(Math.max(0, inner - visible));
			rows.push(
				`${theme.fg("borderMuted", box.vertical)} ${styled ?? content}${pad} ${theme.fg("borderMuted", box.vertical)}`,
			);
		};

		rows.push(
			theme.fg("borderMuted", `${box.topLeft}${box.horizontal.repeat(width - 2)}${box.topRight}`),
		);
		const title = truncateToWidth(this.#options.title, inner);
		line(title, theme.fg("accent", title));

		const prompt = `${theme.cursor} `;
		const filterText = truncateToWidth(this.#filter, Math.max(1, inner - visibleWidth(prompt)));
		line(`${prompt}${filterText}`, `${theme.fg("dim", prompt)}${theme.fg("text", filterText)}`);

		// The list is asked for the inner width, so its own truncation keeps every
		// row inside the box rather than pushing the right border off-screen.
		this.#list.setMaxVisible(this.#maxVisible);
		for (const row of this.#list.render(inner)) {
			line(truncateToWidth(row, inner), truncateToWidth(row, inner));
		}

		const footer = this.#options.footer ?? "enter selects · esc cancels";
		const count = `${this.#filtered.length}/${this.#options.items.length}`;
		const hint = truncateToWidth(`${footer}  ${count}`, inner);
		line(hint, theme.fg("dim", hint));
		rows.push(
			theme.fg(
				"borderMuted",
				`${box.bottomLeft}${box.horizontal.repeat(width - 2)}${box.bottomRight}`,
			),
		);

		this.#cachedRows = rows;
		this.#cachedWidth = width;
		this.#cachedRevision = this.#revision;
		return rows;
	}
}

/** True for input that should extend the filter rather than navigate. */
export function isPrintable(data: string): boolean {
	if (data.length === 0) return false;
	// Escape sequences and control bytes are never filter text.
	if (data.charCodeAt(0) < 0x20 || data.charCodeAt(0) === 0x7f) return false;
	return !data.startsWith("\x1b");
}
