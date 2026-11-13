/**
 * Ctrl+R prompt-history search: omp's {@link HistorySearchComponent} over Lemon's
 * private SQLite prompt history.
 *
 * The component and its keys are omp's, verbatim. This file is only the seam:
 * a {@link HistorySource} backed by {@link PromptHistoryStore} (falling back to
 * the editor's in-memory ↑ ring when persistence is off or storage fails),
 * plus the two things the component assumes an omp host already did, an
 * initialized pi-tui theme and a focused query field.
 */

import { Input } from "@oh-my-pi/pi-tui";
import {
	HistorySearchComponent,
	type HistorySearchEntry,
	type HistorySource,
} from "@oh-my-pi/pi-tui/overlays/history-search";
import { ensureThemeSync } from "@oh-my-pi/pi-tui/theme/theme";
import type { PromptHistoryStore } from "../composer/prompt-history.ts";

export interface HistorySourceOptions {
	/** Saved history; unset or disabled uses the in-memory ring alone. */
	store?: PromptHistoryStore;
	/** The editor's recall ring, oldest first. */
	memory: () => readonly string[];
	/** Called once if storage fails, before the ring is used instead. */
	onStorageError?: (error: unknown) => void;
}

/** Fallback timestamp for ring entries: ring-only prompts were all typed this session. */
const PROCESS_START_SECONDS = Math.floor((Date.now() - process.uptime() * 1000) / 1000);

function tokenize(query: string): string[] {
	return query
		.toLowerCase()
		.split(/[^\p{L}\p{N}]+/u)
		.filter((token) => token.length > 0);
}

/** Newest-first search over saved prompts, or over the ring when nothing is saved. */
export function createHistorySource(options: HistorySourceOptions): HistorySource {
	let storageFailed = false;
	const useStore = (): PromptHistoryStore | undefined =>
		options.store?.enabled && !storageFailed ? options.store : undefined;

	const fromMemory = (query: string, limit: number): HistorySearchEntry[] => {
		const tokens = tokenize(query);
		const entries: HistorySearchEntry[] = [];
		const ring = options.memory();
		for (let index = ring.length - 1; index >= 0 && entries.length < limit; index--) {
			const prompt = ring[index]!;
			const text = prompt.toLowerCase();
			if (tokens.every((token) => text.includes(token))) {
				entries.push({ prompt, created_at: PROCESS_START_SECONDS });
			}
		}
		return entries;
	};

	const query = (text: string, limit: number): HistorySearchEntry[] => {
		const store = useStore();
		if (!store) return fromMemory(text, limit);
		try {
			return store.search(text, limit);
		} catch (error) {
			// One notice, then the ring: a busy or unwritable database must not break typing.
			storageFailed = true;
			options.onStorageError?.(error);
			return fromMemory(text, limit);
		}
	};

	return {
		search: (text, limit) => query(text, limit),
		getRecent: (limit) => query("", limit),
	};
}

/**
 * omp's overlay, made mountable by Lemon's selector: the component is not
 * `Focusable`, so the query field would never draw its cursor. Forward focus
 * to the `Input` the overlay holds.
 */
class FocusedHistorySearch extends HistorySearchComponent {
	#focused = false;

	get focused(): boolean {
		return this.#focused;
	}

	set focused(value: boolean) {
		this.#focused = value;
		for (const child of this.children) {
			if (child instanceof Input) child.focused = value;
		}
	}
}

export interface HistorySearchOptions {
	source: HistorySource;
	/** Fill the composer with the chosen prompt and close the overlay. */
	onSelect: (prompt: string) => void;
	/** Close the overlay, leaving the draft untouched. */
	onCancel: () => void;
	/** Repaint after a debounced search lands. */
	repaint: () => void;
}

export function createHistorySearch(options: HistorySearchOptions): HistorySearchComponent {
	// pi-tui components read a module-level theme that omp initializes at startup;
	// Lemon keeps its own, so install pi-tui's default the first time the overlay opens.
	ensureThemeSync();
	const component = new FocusedHistorySearch(options.source, options.onSelect, options.onCancel);
	component.setOnRequestRender(options.repaint);
	return component;
}
