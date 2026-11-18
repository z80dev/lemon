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
 *   Ctrl+W  preview deleting the selected one (`/session delete`'s preview);
 *           the daemon's stored history goes only after the typed
 *           `/session delete <key> --confirm <key>` and a verified deletion.
 *
 * The overlay itself is a {@link PickerOverlay}: same box, same fuzzy filter,
 * same draft-preserving contract (it never touches the editor). Prompt mode is
 * an inline detail row plus first refusal on keys, not a second overlay — a
 * modal over a modal is how Esc stops meaning one thing. On a native (TSP)
 * sheet the prompt sits in the preview pane under the list, and Ctrl+N / Ctrl+W are
 * action-bar buttons running the same code as the keys.
 */

import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import type { SgrMouseEvent } from "@oh-my-pi/pi-tui/mouse";
import { span, text } from "@oh-my-pi/pi-tui/native/describe";
import { CLOSE_ACTION, pickerAction, pickerAge, pickerDate } from "@oh-my-pi/pi-tui/native/picker";
import { collectSessions, type SessionRow } from "../../commands/session.ts";
import { safeLine } from "../../formatters/base.ts";
import type { ControlPlaneMethods } from "../../protocol/methods.ts";
import type { AppStore } from "../../store/app-store.ts";
import type { NoticeLevel } from "../../store/transcript-model.ts";
import { getTheme } from "../theme/theme.ts";
import {
	confirmAction,
	isPrintable,
	type PickerBadge,
	type PickerItem,
	PickerOverlay,
	type PickerSheet,
} from "./pickers.ts";

const SESSION_COLUMNS: PickerSheet["columns"] = [
	{ id: "runs", format: "dim", priority: 1 },
	{ id: "model", format: "dim", priority: 2 },
	{ id: "when", format: "time", priority: 3 },
];

/** The sheet's preview pane while the list is in charge: empty. */
const NO_PREVIEW: readonly [] = [];

export interface SessionSwitcherHost {
	store: AppStore;
	methods: ControlPlaneMethods;
	/** Mounts the overlay and returns its closer. */
	present(overlay: PickerOverlay): () => void;
	/** Repaints the mounted overlay after its contents changed. */
	repaint(): void;
	switchSession(sessionKey: string): void | Promise<void>;
	createSession(sessionKey: string | undefined, prompt: string | undefined): void | Promise<void>;
	/** Show `/session delete`'s preview for the key; never deletes. */
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
	#searchTimer: NodeJS.Timeout | undefined;
	#searchVersion = 0;
	#searching = false;
	/** Why the last search left the list empty (too long, failed), until the next one. */
	#searchProblem: string | undefined;

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
		this.#searchProblem = undefined;
		this.#overlay = new PickerOverlay({
			title: "sessions",
			items: this.#items(),
			footer: this.#footer(),
			detail: () => this.#detail(),
			remoteFilter: true,
			onFilterChange: (filter) => this.#search(filter),
			onSelect: (item) => void this.#onSelect(item),
			onCancel: () => this.#onCancel(),
			onKey: (data) => this.#onKey(data),
			onMouse: (event) => this.#onMouse(event),
			sheet: {
				icon: "history",
				noun: "sessions",
				layout: "cards",
				placeholder: "Search stored sessions…",
				columns: SESSION_COLUMNS,
				empty: "No sessions match",
				current: () => [this.#host.store.focusedKey],
				subtitle: () => undefined,
				// The inline prompt sits under the list, styled; the plain detail row is the rows view's.
				preview: () =>
					this.#promptMode
						? [
								text([
									span("New session  ", "muted"),
									this.#promptText ? span(this.#promptText) : span("type its first prompt", "dim"),
								]),
							]
						: NO_PREVIEW,
				status: () =>
					this.#searching
						? { state: "loading", message: "Searching stored sessions…" }
						: this.#searchProblem
							? { state: "error", message: this.#searchProblem }
							: undefined,
				actions: () =>
					this.#promptMode
						? [confirmAction("Create session"), { ...CLOSE_ACTION, label: "Back" }]
						: [
								confirmAction("Switch"),
								pickerAction("new", "New session", "ctrl+n"),
								pickerAction("close-session", "Delete session…", "ctrl+w", { danger: true }),
								CLOSE_ACTION,
							],
				// Prompt mode takes the pointer with the keyboard, as for the mouse.
				onEvent: (event) => this.#promptMode && event.kind !== "action",
				onAction: (act) => {
					if (act === "new") this.#startPrompt();
					else if (act === "close-session") this.#closeSelected();
				},
			},
		});
		this.#close = this.#host.present(this.#overlay);
	}

	close(): void {
		if (this.#searchTimer) clearTimeout(this.#searchTimer);
		this.#searchTimer = undefined;
		this.#searchVersion++;
		this.#searching = false;
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
		return this.#searching
			? "searching stored sessions… · esc cancels"
			: "type to search stored sessions · enter switches · ctrl+n new · ctrl+w delete…";
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
			this.#startPrompt();
			return true;
		}
		if (matchesKey(data, "ctrl+w")) {
			this.#closeSelected();
			return true;
		}
		return false;
	}

	#startPrompt(): void {
		this.#promptMode = true;
		this.#promptText = "";
		this.#refresh();
	}

	#closeSelected(): void {
		const selected = this.#overlay?.selected;
		if (!selected) return;
		// The preview lands in the transcript, which this overlay would cover.
		this.close();
		void this.#host.closeSession(selected.value);
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
		this.#host.store.session(item.value).title = this.#rows.find(
			(row) => row.key === item.value,
		)?.title;
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

	#search(filter: string): void {
		if (this.#searchTimer) clearTimeout(this.#searchTimer);
		const version = ++this.#searchVersion;
		const overlay = this.#overlay;
		if (!overlay) return;
		const query = filter.trim();
		if (Buffer.byteLength(query, "utf8") > 512) {
			this.#searching = false;
			this.#searchProblem = "Search is limited to 512 bytes — shorten the query";
			overlay.setItems([], filter);
			overlay.setFooter("search is limited to 512 bytes · shorten the query");
			this.#host.repaint();
			return;
		}
		this.#searching = true;
		this.#searchProblem = undefined;
		// An old row must not be selectable under a new, not-yet-resolved query.
		overlay.setItems([], filter);
		this.#refresh();
		this.#searchTimer = setTimeout(async () => {
			this.#searchTimer = undefined;
			try {
				const rows = await collectSessions(this.#host, query);
				if (version !== this.#searchVersion || this.#overlay !== overlay) return;
				this.#rows = rows;
				this.#searching = false;
				overlay.setItems(this.#items(), filter);
				this.#refresh();
			} catch {
				if (version !== this.#searchVersion || this.#overlay !== overlay) return;
				this.#searching = false;
				this.#searchProblem = "Session search failed — edit the query to retry";
				overlay.setFooter("session search failed · edit the query to retry · esc cancels");
				this.#host.repaint();
			}
		}, 150);
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
	const badges: PickerBadge[] = [];
	if (row.key === focusedKey) badges.push({ text: "current", tone: "accent" });
	if (row.active) badges.push({ text: "busy", tone: "pending" });
	if (row.unread > 0) badges.push({ text: `${row.unread} unread`, tone: "info" });
	if (row.archived) badges.push({ text: "archived", tone: "muted" });
	if (!row.local) {
		badges.push({
			text: "not loaded",
			tone: "muted",
			title: "Stored by the daemon; not loaded here",
		});
	}
	const facts: Record<string, string> = {};
	if (row.model) facts.model = row.model;
	if (row.runCount !== undefined)
		facts.runs = `${row.runCount} run${row.runCount === 1 ? "" : "s"}`;
	const updated =
		row.updatedAtMs !== undefined && row.updatedAtMs > 0 ? row.updatedAtMs : undefined;
	if (updated !== undefined) facts.when = pickerAge(updated, now);
	const key = safeLine(row.key);
	const title = row.title ? safeLine(row.title, 60) : "";
	return {
		value: row.key,
		label: title ? `${title} (${key})` : key,
		description: marks.join(" · "),
		// The sheet's cards put the title on top and the key, a machine string, under it.
		native: {
			label: title || key,
			detail: title ? key : undefined,
			mono: !title,
			...(row.active ? { dot: "pending" as const } : {}),
			...(row.pinned ? { icon: "pin" } : {}),
			...(badges.length > 0 ? { badges } : {}),
			facts,
			...(updated !== undefined ? { title: pickerDate(updated) } : {}),
		},
	};
}
