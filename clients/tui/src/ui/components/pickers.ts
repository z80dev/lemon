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
 *
 * On a Tern Surface Protocol terminal that draws the `picker` kind, the overlay
 * describes itself as a data-first picker sheet instead (`nativeSheet`): Tern
 * draws the head, search field, rows, groups and action bar over the transcript.
 * Keys stay ours — the sheet only mirrors the filter, selection and items — and
 * pointer events run the paths of the keys they stand for (a row click moves the
 * selection, a second click or the primary button is Enter, Close is Esc).
 */

import { type SelectItem, SelectList } from "@oh-my-pi/pi-tui/components/select-list";
import { fuzzyRank } from "@oh-my-pi/pi-tui/fuzzy";
import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import { type MouseRoutable, routeSgrMouseInput, type SgrMouseEvent } from "@oh-my-pi/pi-tui/mouse";
import { text } from "@oh-my-pi/pi-tui/native/describe";
import type {
	DescribeContext,
	NativeChild,
	NativeNode,
	NativeUiEvent,
} from "@oh-my-pi/pi-tui/native/node";
import {
	CLOSE_ACTION,
	type PickerEvent,
	picker,
	pickerAction,
	pickerEvent,
	pickerFuzzyHits,
} from "@oh-my-pi/pi-tui/native/picker";
import { plainText } from "@oh-my-pi/pi-tui/native/spans";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth, visibleWidth } from "@oh-my-pi/pi-tui/utils";
import { getTheme } from "../theme/theme.ts";
import { getSelectListTheme } from "../theme/tui-adapters.ts";

/** The wire props of a native `picker` sheet. */
export type PickerSheetProps = Parameters<typeof picker>[0];
/** One row of a native picker sheet. */
export type NativePickerItem = NonNullable<PickerSheetProps["items"]>[number];
/** One action-bar button of a native picker sheet. */
export type PickerSheetAction = NonNullable<PickerSheetProps["actions"]>[number];

export interface PickerItem extends SelectItem {
	/** Undecorated identifier, when the label includes a current/installed badge. */
	searchValue?: string;
	/**
	 * Native sheet extras for this row (status dot, badges, fact columns, a mono
	 * or undecorated label). Only a TSP terminal reads them; rows ignore them.
	 */
	native?: Partial<Omit<NativePickerItem, "id">>;
	/**
	 * Group heading on the native sheet while the filter is empty; consecutive
	 * items sharing an id form one group. Ranked search results are never grouped.
	 */
	group?: { id: string; label: string };
}

/** What the native sheet says beyond the generic title/filter/list/footer. */
export interface PickerSheet {
	icon?: string;
	/** Plural noun for counts and empty copy ("models", "sessions"). */
	noun?: string;
	size?: PickerSheetProps["size"];
	layout?: PickerSheetProps["layout"];
	placeholder?: string;
	columns?: PickerSheetProps["columns"];
	/** Shown when nothing matches the filter. */
	empty?: string;
	/** Values in use now (the current model, the focused session). */
	current?: () => readonly string[];
	/** The line under the title; defaults to the footer hint. */
	subtitle?: () => PickerSheetProps["subtitle"] | undefined;
	/** Replaces the default preview pane (the detail lines, below the list). */
	preview?: () => readonly NativeChild[];
	/** The whole action bar; defaults to `Select ⏎` and `Close esc`. */
	actions?: () => readonly PickerSheetAction[];
	/** A loading/error state replacing the list body. */
	status?: () => { state: "loading" | "error"; message: string } | undefined;
	/**
	 * First refusal on every pointer event of the sheet, same contract as
	 * {@link PickerOptions.onKey}: return true to consume.
	 */
	onEvent?: (event: PickerEvent) => boolean;
	/**
	 * Action-bar buttons other than the reserved `confirm` (Enter), `close`
	 * (Esc) and `clear` (empties the filter).
	 */
	onAction?: (act: string, value: string | undefined) => void;
}

/**
 * Columns a picker row's frame takes (`│ ` and ` │`); content gets the rest of
 * the render width. Below 8 columns the frame's minimum inner width no longer
 * fits and rows overflow the terminal.
 */
export const PICKER_FRAME_COLUMNS = 4;

/** The default action bar: the primary button is Enter, Close is Esc. */
export const SELECT_ACTIONS: readonly PickerSheetAction[] = [
	pickerAction("confirm", "Select", "enter", { primary: true }),
	CLOSE_ACTION,
];

/** A primary `confirm` button labelled for what Enter does in this picker. */
export function confirmAction(label: string): PickerSheetAction {
	return pickerAction("confirm", label, "enter", { primary: true });
}

/** A badge after a native picker row's label (`current`, `busy`, `3 unread`). */
export type PickerBadge = NonNullable<NativePickerItem["badges"]>[number];

export interface PickerOptions {
	title: string;
	items: PickerItem[];
	/** Hint line under the list. */
	footer?: string;
	/** Rows of list body; the overlay is sized around this. */
	maxVisible?: number;
	/** Prefilled filter text. */
	filter?: string;
	/** Search supplied by a server; the returned rows must not be filtered again. */
	remoteFilter?: boolean;
	onFilterChange?: (filter: string) => void;
	onSelect: (item: PickerItem) => void;
	onCancel?: () => void;
	/**
	 * Keys the host wants first refusal on (the model picker's global-persist
	 * toggle, a back step out of a second stage). Return true to consume.
	 */
	onKey?: (data: string) => boolean;
	/**
	 * Pointer events the host wants first refusal on, same contract as
	 * {@link onKey}. A host that has taken over the keyboard (the switcher's
	 * inline prompt) uses this to take the pointer with it, rather than letting a
	 * stray click confirm a row behind the mode it is in.
	 */
	onMouse?: (event: SgrMouseEvent) => boolean;
	/**
	 * An extra line under the filter, recomputed on every repaint. The session
	 * switcher renders its inline "new session" prompt here; returning undefined
	 * leaves the row out entirely rather than drawing a blank one.
	 */
	detail?: () => string | readonly string[] | undefined;
	/** How a TSP terminal's native picker sheet presents this picker. */
	sheet?: PickerSheet;
}

/**
 * Rank `items` against `query`. Empty queries keep the original order, which is
 * the caller's chosen ordering (recency, relevance) and must not be shuffled.
 */
export function filterItems(items: readonly PickerItem[], query: string): PickerItem[] {
	const trimmed = query.trim();
	if (trimmed.length === 0) return [...items];
	const exact: PickerItem[] = [];
	const fuzzy: PickerItem[] = [];
	const normalized = trimmed.toLowerCase();
	for (const entry of fuzzyRank(
		[...items],
		trimmed,
		(item) => `${item.label} ${item.value} ${item.description ?? ""}`,
	)) {
		const item = entry.item;
		const match =
			item.searchValue?.toLowerCase() === normalized ||
			item.label.toLowerCase() === normalized ||
			item.value.toLowerCase() === normalized;
		(match ? exact : fuzzy).push(item);
	}
	return exact.concat(fuzzy);
}

export class PickerOverlay implements Component, MouseRoutable {
	readonly #options: PickerOptions;
	#filter: string;
	#filtered: PickerItem[];
	#list: SelectList;
	#maxVisible: number;

	#cachedRows: string[] | undefined;
	#cachedWidth = -1;
	#revision = 0;
	#cachedRevision = -1;
	/**
	 * Frame-local row the list body starts on, recorded by the last render. The
	 * chrome above it is fixed except for the optional detail row, so the pointer
	 * cannot be hit-tested against a constant.
	 */
	#listTopRow = 3;

	/** The native sheet, rebuilt only when {@link #revision} moved. */
	#native: { revision: number; node: NativeNode } | undefined;
	/** Native rows for the whole item set, rebuilt only when the set is replaced. */
	#catalogue: { items: readonly PickerItem[]; value: NativePickerItem[] } | undefined;
	/** Preview nodes for the detail lines, kept while the lines are unchanged. */
	#detailNodes: { key: string; nodes: readonly NativeChild[] } | undefined;

	constructor(options: PickerOptions) {
		this.#options = options;
		this.#filter = options.filter ?? "";
		this.#maxVisible = options.maxVisible ?? 12;
		this.#filtered = options.remoteFilter
			? options.items
			: filterItems(options.items, this.#filter);
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

	/** Row-renderer fallback stays when the terminal lacks the `picker` kind. */
	nativeSheet(cx: DescribeContext): boolean {
		return cx.supports("picker");
	}

	describe(cx: DescribeContext): NativeNode | null {
		if (!cx.supports("picker")) return null;
		const memo = this.#native;
		if (memo?.revision === this.#revision) return memo.node;
		const node = this.#describePicker();
		this.#native = { revision: this.#revision, node };
		return node;
	}

	/**
	 * Pointer events from the native sheet, each on the path of the key it
	 * stands for, so a host's own key handling (a typed-slash submit, the
	 * switcher's prompt mode) applies to clicks exactly as to keys.
	 */
	handleNativeEvent(event: NativeUiEvent): void {
		const picked = pickerEvent(event);
		if (!picked) return;
		const sheet = this.#options.sheet;
		if (sheet?.onEvent?.(picked)) {
			this.#invalidateCache();
			return;
		}
		if (picked.kind !== "action") {
			const index = this.#filtered.findIndex((item) => item.value === picked.item);
			if (index < 0) return;
			this.setSelectedIndex(index);
			if (picked.kind === "activate") this.handleInput("\r");
			return;
		}
		switch (picked.act) {
			case "confirm":
				this.handleInput("\r");
				return;
			case "close":
			case "cancel":
				this.handleInput("\x1b");
				return;
			case "clear":
				this.setFilter("");
				return;
			default:
				sheet?.onAction?.(picked.act, picked.value);
				this.#invalidateCache();
		}
	}

	#describePicker(): NativeNode {
		const sheet = this.#options.sheet ?? {};
		const filter = this.#filter;
		const grouped = filter.trim().length === 0;
		const order: (string | { group: string; label: string; count: number })[] = [];
		const hits: Record<string, [number, number][]> = {};
		let hasHits = false;
		const catalogue = this.#nativeCatalogue();
		const filtered = this.#filtered;
		for (let index = 0; index < filtered.length; index++) {
			const item = filtered[index]!;
			const group = item.group;
			if (grouped && group && filtered[index - 1]?.group?.id !== group.id) {
				let count = 1;
				while (filtered[index + count]?.group?.id === group.id) count++;
				order.push({ group: `${group.id}:${index}`, label: group.label, count });
			}
			order.push(item.value);
			if (grouped) continue;
			const label = item.native?.label;
			const ranges = pickerFuzzyHits(
				typeof label === "string" ? label : plainText(item.label),
				filter,
			);
			if (ranges) {
				hits[item.value] = ranges;
				hasHits = true;
			}
		}
		const subtitle = sheet.subtitle ? sheet.subtitle() : this.#options.footer;
		const preview = sheet.preview ? sheet.preview() : this.#previewNodes();
		const status = sheet.status?.();
		const current = sheet.current?.() ?? [];
		return picker(
			{
				title: this.#options.title,
				...(subtitle ? { subtitle } : {}),
				...(sheet.icon ? { icon: sheet.icon } : {}),
				noun: sheet.noun ?? "items",
				size: sheet.size ?? "md",
				layout: sheet.layout ?? "rows",
				preview: preview.length > 0 ? "below" : "none",
				query: filter,
				cursor: filter.length,
				...(sheet.placeholder ? { placeholder: sheet.placeholder } : {}),
				...(sheet.columns ? { columns: sheet.columns } : {}),
				items: catalogue,
				order,
				...(hasHits ? { hits } : {}),
				selected: this.selected?.value ?? null,
				...(current.length > 0 ? { current } : {}),
				total: this.#options.items.length,
				actions: sheet.actions?.() ?? SELECT_ACTIONS,
				state: status?.state ?? "ready",
				...(status ? { message: status.message } : {}),
				empty: sheet.empty ?? "Nothing matches",
				confirm: null,
			},
			preview,
		);
	}

	/** Native rows for every item, by value; undecorated labels (no ANSI). */
	#nativeCatalogue(): NativePickerItem[] {
		const items = this.#options.items;
		if (this.#catalogue?.items === items) return this.#catalogue.value;
		const value = items.map((item): NativePickerItem => {
			const description = item.description ? plainText(item.description) : "";
			return {
				id: item.value,
				label: plainText(item.label),
				...(description ? { detail: description } : {}),
				...(item.disabled ? { disabled: true as const } : {}),
				...item.native,
			};
		});
		this.#catalogue = { items, value };
		return value;
	}

	/** The detail lines as the sheet's preview pane, below the list. */
	#previewNodes(): readonly NativeChild[] {
		const detail = this.#options.detail?.();
		const lines = detail === undefined ? [] : typeof detail === "string" ? [detail] : detail;
		const key = lines.join("\n");
		if (this.#detailNodes?.key === key) return this.#detailNodes.nodes;
		const nodes = lines.map((line) => text(plainText(line), { wrap: "word" }));
		this.#detailNodes = { key, nodes };
		return nodes;
	}

	setSelectedIndex(index: number): void {
		this.#list.setSelectedIndex(index);
		this.#invalidateCache();
	}

	setFilter(filter: string): void {
		if (filter === this.#filter) return;
		this.#filter = filter;
		this.#filtered = this.#options.remoteFilter
			? this.#options.items
			: filterItems(this.#options.items, filter);
		this.#list = this.#buildList();
		this.#invalidateCache();
		this.#options.onFilterChange?.(filter);
	}

	/** Replace the hint line (a mode change inside one overlay). */
	setFooter(footer: string): void {
		if (this.#options.footer === footer) return;
		this.#options.footer = footer;
		this.#invalidateCache();
	}

	/** Swap the item set (a second picker stage) and reset the filter. */
	setItems(items: PickerItem[], filter = ""): void {
		this.#options.items = items;
		this.#filter = filter;
		this.#filtered = this.#options.remoteFilter ? items : filterItems(items, filter);
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

	/**
	 * Pointer events, at coordinates local to the overlay's own frame.
	 *
	 * Wheel ticks scroll the list wherever the pointer is — inside a modal the
	 * wheel is the list's, since the terminal's own scrollback is not reachable
	 * while the alternate screen is up. Clicks and hover only count on a row that
	 * hit-tests to an item.
	 */
	routeMouse(event: SgrMouseEvent, line: number, _col: number): void {
		if (this.#options.onMouse?.(event)) {
			this.#invalidateCache();
			return;
		}
		this.#list.routeMouse(event, line - this.#listTopRow, 0);
		this.#invalidateCache();
	}

	handleInput(data: string): void {
		if (data.startsWith("\x1b[200~") && data.endsWith("\x1b[201~")) {
			const pasted = data.slice(6, -6).replace(/\r\n|\r|\n/g, " ");
			if (isPrintable(pasted)) {
				if (!this.#options.onKey?.(pasted)) this.setFilter(this.#filter + pasted);
				this.#invalidateCache();
			}
			return;
		}
		// Mouse reports arrive on the same channel as keys; they are never filter
		// text and must not reach the list's own key handling. The screen row is
		// the frame-local row because overlays are mounted at the window origin
		// (see SelectorController), which is also what makes tracking legal: the
		// terminal only reports pointers while the alternate screen is up.
		const routed = routeSgrMouseInput(data, (event) => {
			this.routeMouse(event, event.row, event.col);
			return true;
		});
		if (routed) return;
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
		const inner = Math.max(4, width - PICKER_FRAME_COLUMNS);
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

		const detail = this.#options.detail?.();
		if (detail !== undefined) {
			for (const value of typeof detail === "string" ? [detail] : detail) {
				const text = truncateToWidth(value, inner);
				line(text, theme.fg("info", text));
			}
		}
		// Where the list body starts, for pointer hit-testing.
		this.#listTopRow = rows.length;

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
