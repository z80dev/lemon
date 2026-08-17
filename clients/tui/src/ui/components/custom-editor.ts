/**
 * The prompt editor.
 *
 * Everything pi-tui's {@link Editor} already does well (wrapping, undo, paste
 * markers, autocomplete popups, IME) is inherited untouched. What this subclass
 * adds is the key policy the client needs *before* the base editor sees a
 * keystroke:
 *
 *   Ctrl+C   a non-empty draft is cleared; an empty one aborts the live run;
 *            with nothing running, twice in a row quits.
 *   Ctrl+D   quits on an empty draft, deletes forward otherwise.
 *   Ctrl+G   hands the draft to $EDITOR.
 *   Esc Esc  discards the draft — recoverable with ↑, because a discard the
 *            user did not mean is otherwise unrecoverable.
 *   ↑ / ↓    recall sent prompts while the draft is empty.
 *
 * Submission funnels through one callback, {@link CustomEditorOptions.onSubmit}.
 * That single seam is where P4 layers queue / steer / interrupt; nothing else in
 * the client sends a prompt.
 */

import { CombinedAutocompleteProvider } from "@oh-my-pi/pi-tui/autocomplete";
import { Editor, type EditorTheme } from "@oh-my-pi/pi-tui/components/editor";
import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import type { NoticeLevel } from "../../store/transcript-model.ts";

/** Window in which a second Ctrl+C quits. */
export const EXIT_CONFIRM_MS = 2000;
/** Window in which a second Esc discards the draft. */
export const ESC_DISCARD_MS = 800;
/** How many sent prompts ↑ can walk back through. */
export const HISTORY_LIMIT = 100;

export interface CustomEditorOptions {
	theme: EditorTheme;
	/** The one submission seam. Slash/shell handling happens downstream of it. */
	onSubmit: (text: string) => void | Promise<void>;
	/** Abort the run in flight. Return true when there was one. */
	onAbort?: () => boolean;
	onQuit?: (code: number) => void;
	/** Ctrl+G / `/editor`. */
	onExternalEdit?: () => void | Promise<void>;
	notice?: (text: string, level?: NoticeLevel) => void;
	/** Called after a key changed something the host may want repainted. */
	requestRender?: () => void;
	/** Clock seam for the double-press windows. */
	now?: () => number;
}

export class CustomEditor extends Editor {
	readonly #options: CustomEditorOptions;
	readonly #now: () => number;

	/** Sent prompts, oldest first. */
	readonly #history: string[] = [];
	/** Position while walking history; undefined when not recalling. */
	#historyIndex: number | undefined;
	/** The draft that was on screen when recall started. */
	#stashed = "";
	#exitArmedAt = 0;
	#escapeAt = 0;

	constructor(options: CustomEditorOptions) {
		super(options.theme);
		this.#options = options;
		this.#now = options.now ?? Date.now;
		// Base Editor exposes submission as a property; ours is the only writer.
		this.onSubmit = (text: string) => this.#submit(text);
	}

	/** Sent prompts, oldest first (the ↑ ring). */
	get history(): readonly string[] {
		return this.#history;
	}

	/** Install slash-command and file-path completion. */
	setCommands(
		commands: Array<{ name: string; description?: string; argumentHint?: string }>,
		basePath = process.cwd(),
	): void {
		this.setAutocompleteProvider(
			new CombinedAutocompleteProvider(
				commands.map((command) => ({
					name: command.name,
					description: command.description,
					argumentHint: command.argumentHint,
					allowArgs: true,
				})),
				basePath,
			),
		);
	}

	/** Reset the double-press arms — used after any state-changing event. */
	disarm(): void {
		this.#exitArmedAt = 0;
		this.#escapeAt = 0;
	}

	/** Push a prompt onto the recall ring without sending it. */
	rememberDraft(text: string): void {
		const trimmed = text.trim();
		if (trimmed.length === 0) return;
		if (this.#history[this.#history.length - 1] === text) return;
		this.#history.push(text);
		if (this.#history.length > HISTORY_LIMIT) this.#history.shift();
	}

	override handleInput(data: string): void {
		if (this.#intercept(data)) {
			this.#options.requestRender?.();
			return;
		}
		// Any other key ends a history walk: the buffer is the user's again.
		if (this.#historyIndex !== undefined && !isHistoryKey(data)) {
			this.#historyIndex = undefined;
		}
		if (!matchesKey(data, "escape")) this.#escapeAt = 0;
		if (!matchesKey(data, "ctrl+c")) this.#exitArmedAt = 0;
		super.handleInput(data);
	}

	/** Returns true when the key was consumed and must not reach the editor. */
	#intercept(data: string): boolean {
		if (matchesKey(data, "ctrl+c")) {
			this.#onCtrlC();
			return true;
		}
		if (matchesKey(data, "ctrl+d")) {
			if (this.getText().length > 0) return false;
			this.#options.onQuit?.(0);
			return true;
		}
		if (matchesKey(data, "ctrl+g")) {
			void this.#options.onExternalEdit?.();
			return true;
		}
		if (matchesKey(data, "escape")) {
			return this.#onEscape();
		}
		if (matchesKey(data, "up")) {
			return this.#recall(-1);
		}
		if (matchesKey(data, "down")) {
			return this.#recall(1);
		}
		return false;
	}

	#onCtrlC(): void {
		const draft = this.getText();
		if (draft.length > 0) {
			// Not lost: a cleared draft is still recallable with ↑.
			this.rememberDraft(draft);
			this.setText("");
			this.#historyIndex = undefined;
			this.#exitArmedAt = 0;
			return;
		}
		if (this.#options.onAbort?.()) {
			this.#exitArmedAt = 0;
			return;
		}
		const now = this.#now();
		if (now - this.#exitArmedAt < EXIT_CONFIRM_MS) {
			this.#options.onQuit?.(0);
			return;
		}
		this.#exitArmedAt = now;
		this.#options.notice?.("press Ctrl+C again to quit");
	}

	#onEscape(): boolean {
		// An open autocomplete popup owns Escape.
		if (this.isShowingAutocomplete()) return false;
		const now = this.#now();
		if (now - this.#escapeAt < ESC_DISCARD_MS && this.getText().length > 0) {
			this.rememberDraft(this.getText());
			this.setText("");
			this.#historyIndex = undefined;
			this.#escapeAt = 0;
			this.#options.notice?.("draft discarded (↑ to bring it back)");
			return true;
		}
		this.#escapeAt = now;
		return false;
	}

	/** Walk the recall ring. `-1` is older, `+1` newer. */
	#recall(direction: -1 | 1): boolean {
		if (this.#history.length === 0) return false;
		if (this.#historyIndex === undefined) {
			// Only an empty draft opts into recall; otherwise ↑ moves the cursor.
			if (direction !== -1 || this.getText().length > 0) return false;
			this.#stashed = this.getText();
			this.#historyIndex = this.#history.length - 1;
			this.setText(this.#history[this.#historyIndex]);
			return true;
		}
		const next = this.#historyIndex + direction;
		if (next < 0) return true;
		if (next >= this.#history.length) {
			this.#historyIndex = undefined;
			this.setText(this.#stashed);
			return true;
		}
		this.#historyIndex = next;
		this.setText(this.#history[next]);
		return true;
	}

	/**
	 * The base editor has already expanded paste markers, trimmed, and emptied
	 * the buffer by the time this runs — `text` is the real prompt bytes.
	 */
	async #submit(text: string): Promise<void> {
		this.#historyIndex = undefined;
		this.disarm();
		if (text.trim().length === 0) return;
		this.rememberDraft(text);
		this.addToHistory(text);
		await this.#options.onSubmit(text);
	}
}

function isHistoryKey(data: string): boolean {
	return matchesKey(data, "up") || matchesKey(data, "down");
}
