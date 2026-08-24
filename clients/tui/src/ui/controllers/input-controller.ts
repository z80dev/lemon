/**
 * Global keys — the ones that work regardless of what has focus.
 *
 * They are declared as keybindings rather than matched inline so `/help` (and,
 * later, a user config) has one place to read them from, and so a conflict with
 * pi-tui's own bindings is visible instead of mysterious.
 *
 * The listener defers to overlays: while one is up it owns the keyboard, or Esc
 * inside a picker would also fire whatever global binding Esc has.
 */

import { KeybindingsManager, TUI_KEYBINDINGS } from "@oh-my-pi/pi-tui/keybindings";
import type { TUI } from "@oh-my-pi/pi-tui/tui";

export const LEMON_KEYBINDINGS = {
	"lemon.picker.model": { defaultKeys: "ctrl+o", description: "Pick a model" },
	"lemon.sessions.switch": { defaultKeys: "ctrl+x", description: "Switch session" },
	"lemon.editor.external": { defaultKeys: "ctrl+g", description: "Edit the draft in $EDITOR" },
	"lemon.transcript.clear": { defaultKeys: "ctrl+l", description: "Clear the transcript" },
	"lemon.queue.focus": { defaultKeys: "ctrl+q", description: "Edit the queued prompts" },
} as const;

export type LemonKeybinding = keyof typeof LEMON_KEYBINDINGS;

export interface InputControllerOptions {
	tui: TUI;
	/** True while a picker/switcher owns the keyboard. */
	hasOverlay: () => boolean;
	openModelPicker: () => void | Promise<void>;
	openSessionSwitcher?: () => void | Promise<void>;
	openExternalEditor?: () => void | Promise<void>;
	clearTranscript?: () => void;
	/** Focus the queue panel. False when there is nothing queued to focus. */
	focusQueue?: () => boolean;
	notice?: (text: string) => void;
}

export class InputController {
	readonly #options: InputControllerOptions;
	readonly #keys: KeybindingsManager;
	#dispose: (() => void) | undefined;

	constructor(options: InputControllerOptions) {
		this.#options = options;
		this.#keys = new KeybindingsManager({ ...TUI_KEYBINDINGS, ...LEMON_KEYBINDINGS });
	}

	get keybindings(): KeybindingsManager {
		return this.#keys;
	}

	/** One line per global binding, for `/help` and the banner. */
	describe(): string[] {
		return Object.entries(LEMON_KEYBINDINGS).map(
			([name, definition]) => `${definition.defaultKeys} — ${definition.description ?? name}`,
		);
	}

	attach(): void {
		if (this.#dispose) return;
		this.#dispose = this.#options.tui.addInputListener((data) => {
			if (this.#options.hasOverlay()) return undefined;
			if (this.#matches(data, "lemon.picker.model")) {
				void this.#options.openModelPicker();
				return { consume: true };
			}
			if (this.#matches(data, "lemon.sessions.switch")) {
				if (this.#options.openSessionSwitcher) void this.#options.openSessionSwitcher();
				else this.#options.notice?.("the session switcher arrives with multi-session support");
				return { consume: true };
			}
			if (this.#matches(data, "lemon.transcript.clear")) {
				this.#options.clearTranscript?.();
				return { consume: true };
			}
			if (this.#matches(data, "lemon.queue.focus")) {
				if (this.#options.focusQueue?.() === false) {
					this.#options.notice?.("nothing is queued");
				}
				return { consume: true };
			}
			// Ctrl+G, Ctrl+C and Ctrl+D belong to the editor, which has focus in
			// every normal case; they are only handled here when it does not.
			if (this.#matches(data, "lemon.editor.external") && !this.#editorFocused()) {
				if (this.#options.openExternalEditor) void this.#options.openExternalEditor();
				return { consume: true };
			}
			return undefined;
		});
	}

	dispose(): void {
		this.#dispose?.();
		this.#dispose = undefined;
	}

	#editorFocused(): boolean {
		const focused = this.#options.tui.getFocused();
		return focused !== null && typeof (focused as { getText?: unknown }).getText === "function";
	}

	#matches(data: string, binding: LemonKeybinding): boolean {
		// The manager is typed against pi-tui's own binding union; ours are added
		// through the same definitions map, so the cast is the declared extension
		// point rather than a hole.
		return this.#keys.matches(data, binding as never);
	}
}
