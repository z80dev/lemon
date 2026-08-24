/**
 * The pending-prompt panel.
 *
 * Sits below the transcript and above the status line, so it is inside the
 * repaintable live region: it can grow, shrink and disappear between frames
 * without ever stranding a row in native scrollback. That placement is the
 * reason it is a plain {@link Component} rather than a transcript block — it is
 * not history, it is a mutable list of things that have not happened yet.
 *
 * Only three items are shown at a time. A queue is a working set, and a panel
 * that grows without bound would push the editor off a short terminal; the
 * window slides with the selection and the remainder is counted.
 */

import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth } from "@oh-my-pi/pi-tui/utils";
import type { QueueItem } from "../../store/queue-store.ts";
import { getTheme } from "../theme/theme.ts";

/** How many queued prompts are listed before the "…N more" tail. */
export const QUEUE_WINDOW = 3;

export interface QueuePanelOptions {
	/** Enter: pull the item back into the editor (and out of the queue). */
	onEdit: (item: QueueItem) => void;
	/** `d` / Delete: drop the item. */
	onDelete: (item: QueueItem) => void;
	/** Esc: hand focus back to the editor. */
	onBlur: () => void;
	/** Called when a key changed what the panel shows. */
	requestRender?: () => void;
}

export class QueuePanelComponent implements Component {
	/** Written by `TUI.setFocus`; also set directly by the controller. */
	focused = false;

	readonly #options: QueuePanelOptions;
	#items: readonly QueueItem[] = [];
	#selected = 0;

	#cachedRows: readonly string[] | undefined;
	#cachedWidth = -1;
	#cachedKey = "";

	constructor(options: QueuePanelOptions) {
		this.#options = options;
	}

	get items(): readonly QueueItem[] {
		return this.#items;
	}

	/** Index of the highlighted row, clamped to the list. */
	get selectedIndex(): number {
		return this.#selected;
	}

	get selected(): QueueItem | undefined {
		return this.#items[this.#selected];
	}

	/** False when there is nothing to show; the host unmounts on false. */
	get visible(): boolean {
		return this.#items.length > 0;
	}

	/**
	 * Swap in the current queue. The selection is kept on the same *position*
	 * rather than the same item: deleting row 2 should leave the cursor on what
	 * is now row 2, which is how every other list in the client behaves.
	 */
	update(items: readonly QueueItem[]): void {
		this.#items = items;
		this.#selected = Math.max(0, Math.min(this.#selected, items.length - 1));
		this.#cachedRows = undefined;
	}

	handleInput(data: string): void {
		if (this.#items.length === 0) {
			this.#options.onBlur();
			return;
		}
		// Ctrl+C never edits or deletes: it means "stop what you are doing", and
		// here the least surprising reading of that is to leave the panel.
		if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) {
			this.#options.onBlur();
			return;
		}
		if (matchesKey(data, "up") || matchesKey(data, "ctrl+p")) {
			this.#move(-1);
			return;
		}
		if (matchesKey(data, "down") || matchesKey(data, "ctrl+n")) {
			this.#move(1);
			return;
		}
		if (matchesKey(data, "enter")) {
			const item = this.selected;
			if (item) this.#options.onEdit(item);
			return;
		}
		if (matchesKey(data, "delete") || matchesKey(data, "backspace") || data === "d") {
			const item = this.selected;
			if (item) this.#options.onDelete(item);
			return;
		}
	}

	invalidate(): void {
		this.#cachedRows = undefined;
	}

	render(width: number): readonly string[] {
		const key = this.#cacheKey();
		if (this.#cachedRows && this.#cachedWidth === width && this.#cachedKey === key) {
			return this.#cachedRows;
		}
		const rows = this.#build(width);
		this.#cachedRows = rows;
		this.#cachedWidth = width;
		this.#cachedKey = key;
		return rows;
	}

	// -- internals -----------------------------------------------------------

	#move(direction: -1 | 1): void {
		const next = this.#selected + direction;
		if (next < 0 || next >= this.#items.length) return;
		this.#selected = next;
		this.#cachedRows = undefined;
		this.#options.requestRender?.();
	}

	#cacheKey(): string {
		return [
			this.focused ? "f" : "-",
			this.#selected,
			this.#items.length,
			this.#items.map((item) => `${item.id}:${item.state}:${item.text.length}`).join(","),
		].join("|");
	}

	#build(width: number): readonly string[] {
		if (this.#items.length === 0) return EMPTY;
		const theme = getTheme();
		const rows: string[] = [];
		const clamp = (text: string) => truncateToWidth(text, width);

		const hint = this.focused ? "↑↓ select · enter edits · d deletes · esc done" : "ctrl+q to edit";
		const header = `queue · ${this.#items.length} waiting · ${hint}`;
		rows.push(theme.fg(this.focused ? "accent" : "dim", clamp(header)));

		const { start, end } = this.#window();
		for (let index = start; index < end; index++) {
			const item = this.#items[index]!;
			const marker = this.focused && index === this.#selected ? theme.cursor : " ";
			const offline = item.state === "waiting-connection" ? "(offline) " : "";
			const line = clamp(`${marker} ${index + 1}. ${offline}${oneLine(item.text)}`);
			const selected = this.focused && index === this.#selected;
			rows.push(
				selected
					? theme.fg("accent", line)
					: theme.fg(item.state === "waiting-connection" ? "warning" : "muted", line),
			);
		}
		const hidden = this.#items.length - (end - start);
		if (hidden > 0) rows.push(theme.fg("dim", clamp(`  …${hidden} more`)));
		return rows;
	}

	/** The visible slice, slid just far enough to keep the selection inside it. */
	#window(): { start: number; end: number } {
		const total = this.#items.length;
		if (total <= QUEUE_WINDOW) return { start: 0, end: total };
		const start = Math.max(0, Math.min(this.#selected - (QUEUE_WINDOW - 1), total - QUEUE_WINDOW));
		return { start, end: start + QUEUE_WINDOW };
	}
}

const EMPTY: readonly string[] = Object.freeze([]);

/** Queued prompts are multi-line often enough that the list must flatten them. */
function oneLine(text: string): string {
	return text.replace(/\s+/g, " ").trim();
}
