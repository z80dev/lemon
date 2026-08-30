/**
 * The Ctrl+X session switcher.
 *
 * One list of everything the client could be looking at: the sessions running
 * server-side (`sessions.active.list`), the ones the daemon has stored
 * (`sessions.list`), and the ones this client already holds a transcript for.
 * They are merged by key, so a session that is all three appears once.
 *
 * Beyond Enter it carries the two verbs a list of sessions needs:
 *
 *   Ctrl+N  mint one — the row turns into an inline prompt, and what is typed
 *           there becomes the new session's first message. A session with no
 *           first prompt exists only in this client until something is sent, so
 *           asking for the prompt up front is asking for the session.
 *   Ctrl+W  close the selected one, after a confirm step, because closing takes
 *           the daemon's stored history with it.
 *
 * The overlay itself is a {@link PickerOverlay}: same box, same fuzzy filter,
 * same draft-preserving contract (it never touches the editor). Prompt mode is
 * an inline detail row plus first refusal on keys, not a second overlay — a
 * modal over a modal is how Esc stops meaning one thing.
 */

import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import type { SgrMouseEvent } from "@oh-my-pi/pi-tui/mouse";
import { collectSessions, type SessionRow } from "../../commands/session.ts";
import type { ControlPlaneMethods } from "../../protocol/methods.ts";
import type { AppStore } from "../../store/app-store.ts";
import type { NoticeLevel } from "../../store/transcript-model.ts";
import { getTheme } from "../theme/theme.ts";
import { isPrintable, type PickerItem, PickerOverlay } from "./pickers.ts";

export interface SessionSwitcherHost {
	store: AppStore;
	methods: ControlPlaneMethods;
	/** Mounts the overlay and returns its closer. */
	present(overlay: PickerOverlay): () => void;
	/** Repaints the mounted overlay after its contents changed. */
	repaint(): void;
	switchSession(sessionKey: string): void | Promise<void>;
	createSession(sessionKey: string | undefined, prompt: string | undefined): void | Promise<void>;
	closeSession(sessionKey: string): void | Promise<void>;
	notice(text: string, level?: NoticeLevel): void;
	/** Clock seam so row ages are assertable. */
	now?: () => number;
}

export class SessionSwitcher {
	readonly #host: SessionSwitcherHost;
	#overlay: PickerOverlay | undefined;
	#close: (() => void) | undefined;
	#rows: SessionRow[] = [];
	#promptMode = false;
	#promptText = "";

	constructor(host: SessionSwitcherHost) {
		this.#host = host;
	}

	get isOpen(): boolean {
		return this.#overlay !== undefined;
	}

	get overlay(): PickerOverlay | undefined {
		return this.#overlay;
	}

	/** True while the inline "new session" prompt owns the keyboard. */
	get promptMode(): boolean {
		return this.#promptMode;
	}

	get promptText(): string {
		return this.#promptText;
	}

	/** The merged rows behind the last open, in display order. */
	get rows(): readonly SessionRow[] {
		return this.#rows;
	}

	async open(): Promise<void> {
		this.#rows = await collectSessions(this.#host);
		this.#promptMode = false;
		this.#promptText = "";
		const focusedKey = this.#host.store.focusedKey;
		if (this.#rows.length === 0) {
			// The focused session always exists locally, so an empty merge means the
			// daemon answered nothing and the local store was somehow empty too.
			this.#rows = [
				{
					key: focusedKey,
					active: false,
					local: true,
					unread: 0,
					pinned: false,
					archived: false,
				},
			];
		}
		this.#overlay = new PickerOverlay({
			title: "sessions",
			items: this.#items(),
			footer: this.#footer(),
			detail: () => this.#detail(),
			onSelect: (item) => void this.#onSelect(item),
			onCancel: () => this.#onCancel(),
			onKey: (data) => this.#onKey(data),
			onMouse: (event) => this.#onMouse(event),
		});
		this.#close = this.#host.present(this.#overlay);
	}

	close(): void {
		this.#close?.();
		this.#close = undefined;
		this.#overlay = undefined;
		this.#promptMode = false;
		this.#promptText = "";
	}

	// -- rows ----------------------------------------------------------------

	#items(): PickerItem[] {
		const now = this.#host.now?.() ?? Date.now();
		const focusedKey = this.#host.store.focusedKey;
		return this.#rows.map((row) => describeSessionRow(row, focusedKey, now));
	}

	#footer(): string {
		if (this.#promptMode) return "enter creates the session with this prompt · esc goes back";
		return "enter switches · ctrl+n new · ctrl+w close · esc cancels";
	}

	/** The inline prompt row, or nothing while the list is in charge. */
	#detail(): string | undefined {
		if (!this.#promptMode) return undefined;
		const theme = getTheme();
		return `new session ${theme.cursor} ${this.#promptText}`;
	}

	// -- keys ----------------------------------------------------------------

	#onKey(data: string): boolean {
		if (this.#promptMode) return this.#onPromptKey(data);
		if (matchesKey(data, "ctrl+n")) {
			this.#promptMode = true;
			this.#promptText = "";
			this.#refresh();
			return true;
		}
		if (matchesKey(data, "ctrl+w")) {
			const selected = this.#overlay?.selected;
			if (selected) {
				// The confirm overlay replaces this one; reopening afterwards would
				// fight the user's own next keystroke.
				this.close();
				void this.#host.closeSession(selected.value);
			}
			return true;
		}
		return false;
	}

	/**
	 * Prompt mode consumes everything: while it is up the keyboard is a text
	 * field, and letting an unhandled key fall through to the list would move a
	 * selection the user cannot see the effect of.
	 */
	#onPromptKey(data: string): boolean {
		if (matchesKey(data, "enter")) {
			const prompt = this.#promptText.trim();
			this.close();
			void this.#host.createSession(undefined, prompt.length > 0 ? prompt : undefined);
			return true;
		}
		if (matchesKey(data, "escape")) {
			this.#promptMode = false;
			this.#promptText = "";
			this.#refresh();
			return true;
		}
		if (matchesKey(data, "backspace")) {
			if (this.#promptText.length === 0) this.#promptMode = false;
			else this.#promptText = this.#promptText.slice(0, -1);
			this.#refresh();
			return true;
		}
		if (matchesKey(data, "ctrl+u")) {
			this.#promptText = "";
			this.#refresh();
			return true;
		}
		if (isPrintable(data)) {
			this.#promptText += data;
			this.#refresh();
			return true;
		}
		return true;
	}

	/**
	 * Prompt mode takes the pointer along with the keyboard: a click that
	 * confirmed a row would throw away the prompt being typed, for a gesture the
	 * user aimed at a list they are not in charge of. The wheel still scrolls —
	 * looking is not choosing.
	 */
	#onMouse(event: SgrMouseEvent): boolean {
		return this.#promptMode && event.wheel === null;
	}

	async #onSelect(item: PickerItem): Promise<void> {
		this.close();
		await this.#host.switchSession(item.value);
	}

	#onCancel(): void {
		if (this.#promptMode) {
			this.#promptMode = false;
			this.#promptText = "";
			this.#refresh();
			return;
		}
		this.close();
	}

	/** Repaint the open overlay after a mode change (footer + detail row move). */
	#refresh(): void {
		if (!this.#overlay) return;
		this.#overlay.setFooter(this.#footer());
		this.#overlay.invalidate();
		this.#host.repaint();
	}
}

/** How long ago, in the shortest form that is still true. */
export function relativeAge(at: number | undefined, now: number): string | undefined {
	if (at === undefined || !Number.isFinite(at) || at <= 0) return undefined;
	const seconds = Math.max(0, Math.round((now - at) / 1000));
	if (seconds < 60) return `${seconds}s ago`;
	const minutes = Math.round(seconds / 60);
	if (minutes < 60) return `${minutes}m ago`;
	const hours = Math.round(minutes / 60);
	if (hours < 24) return `${hours}h ago`;
	return `${Math.round(hours / 24)}d ago`;
}

/**
 * One row: the key, then the facts that decide whether to switch to it — the
 * model it runs, whether it is working, what arrived since it was last on
 * screen, and how long ago that was.
 */
export function describeSessionRow(row: SessionRow, focusedKey: string, now: number): PickerItem {
	const theme = getTheme();
	const marks = [
		row.key === focusedKey ? "current" : undefined,
		row.model,
		// The spinner glyph is the theme's first frame rather than an animation:
		// a list row that animates would repaint the overlay forever.
		row.active ? `${theme.spinnerFrames[0]} busy` : "idle",
		row.unread > 0 ? `${row.unread} unread` : undefined,
		row.runCount !== undefined ? `${row.runCount} run(s)` : undefined,
		row.pinned ? "pinned" : undefined,
		row.archived ? "archived" : undefined,
		row.local ? undefined : "not loaded",
		relativeAge(row.updatedAtMs, now),
	].filter((mark): mark is string => Boolean(mark));
	return {
		value: row.key,
		label: row.title ? `${shortTitle(row.title)} (${row.key})` : row.key,
		description: marks.join(" · "),
	};
}

function shortTitle(title: string): string {
	const flat = title.replace(/\s+/g, " ").trim();
	return flat.length > 60 ? `${flat.slice(0, 59)}…` : flat;
}
