/**
 * Global keys — the ones that work regardless of what has focus.
 *
 * They are declared as keybindings rather than matched inline so config and
 * help share the same action registry.
 *
 * The listener defers to overlays: while one is up it owns the keyboard, or Esc
 * inside a picker would also fire whatever global binding Esc has.
 */

import { type KeybindingsManager, TUI_KEYBINDINGS } from "@oh-my-pi/pi-tui/keybindings";
import type { TUI } from "@oh-my-pi/pi-tui/tui";
import { resolveKeybindings } from "../../config.ts";
import type { CommandPaletteMode } from "./command-palette.ts";

export const LEMON_KEYBINDINGS = {
	"lemon.picker.model": { defaultKeys: "ctrl+o", description: "Pick a model" },
	"lemon.picker.thinking": {
		defaultKeys: "shift+tab",
		description: "Pick the session thinking level",
	},
	"lemon.sessions.switch": { defaultKeys: "ctrl+x", description: "Switch session" },
	"lemon.editor.external": { defaultKeys: "ctrl+g", description: "Edit the draft in $EDITOR" },
	"lemon.transcript.clear": { defaultKeys: "ctrl+l", description: "Clear the transcript" },
	"lemon.queue.focus": { defaultKeys: "ctrl+q", description: "Edit the queued prompts" },
	"lemon.transcript.toggleLatest": {
		defaultKeys: "ctrl+r",
		description: "Expand/collapse the latest tool card or thinking block",
	},
	"lemon.transcript.cycleDetail": {
		defaultKeys: "ctrl+t",
		description: "Cycle detail for every card: collapsed → expanded → default",
	},
	"lemon.palette.open": {
		defaultKeys: "ctrl+p",
		description: "Search commands, skills and prompts",
	},
	"lemon.tasks.toggle": { defaultKeys: "alt+a", description: "Show/hide live subagent tree" },
	"lemon.omp.toggle": { defaultKeys: "alt+m", description: "Show/hide omp delegate sessions" },
	"lemon.tools.toggle": { defaultKeys: "alt+o", description: "Collapse/expand all tool output" },
	"lemon.tools.diff": { defaultKeys: "alt+d", description: "Inspect the latest edit diff" },
	"lemon.clipboard.copyLast": {
		defaultKeys: "alt+shift+c",
		description: "Copy the last assistant reply",
	},
	"lemon.plan.toggle": { defaultKeys: [] as [], description: "Toggle plan mode" },
	"lemon.model.cycle": { defaultKeys: [] as [], description: "Cycle to the next model" },
} as const;

export type LemonKeybinding = keyof typeof LEMON_KEYBINDINGS;

export interface InputControllerOptions {
	tui: TUI;
	userBindings?: unknown;
	/** True while a picker/switcher owns the keyboard. */
	hasOverlay: () => boolean;
	openModelPicker: () => void | Promise<void>;
	openThinkingPicker?: () => void | Promise<void>;
	openSessionSwitcher?: () => void | Promise<void>;
	openExternalEditor?: () => void | Promise<void>;
	clearTranscript?: () => void;
	/** Focus the queue panel. False when there is nothing queued to focus. */
	focusQueue?: () => boolean;
	/** Toggle the latest tool card or reasoning block. False when there is none. */
	toggleLatest?: () => boolean;
	/** Cycle the global accordion override and apply it to the transcript. */
	cycleDetail?: () => void;
	openCommandPalette?: (mode: CommandPaletteMode) => void | Promise<void>;
	isComposerEmpty?: () => boolean;
	toggleTaskTree?: () => void;
	toggleOmpPanel?: () => void;
	toggleToolOutputs?: () => void;
	openDiff?: () => void;
	copyLastReply?: () => void | Promise<void>;
	togglePlan?: () => void | Promise<void>;
	cycleModel?: () => void | Promise<void>;
	notice?: (text: string) => void;
}

export class InputController {
	readonly #options: InputControllerOptions;
	readonly #keys: KeybindingsManager;
	#dispose: (() => void) | undefined;

	constructor(options: InputControllerOptions) {
		this.#options = options;
		const { manager, issues } = resolveKeybindings(options.userBindings, {
			...TUI_KEYBINDINGS,
			...LEMON_KEYBINDINGS,
		});
		this.#keys = manager;
		if (issues.length > 0) options.notice?.(`Keybindings: ${issues.join("; ")}`);
	}

	get keybindings(): KeybindingsManager {
		return this.#keys;
	}

	/** One line per global binding, for `/help` and the banner. */
	describe(): string[] {
		return Object.entries(LEMON_KEYBINDINGS).map(
			([name, definition]) =>
				`${this.#keys.getKeys(name as never).join(", ") || "unbound"} — ${definition.description}`,
		);
	}

	attach(): void {
		if (this.#dispose) return;
		this.#dispose = this.#options.tui.addInputListener((data) => {
			if (this.#options.hasOverlay()) return undefined;
			const typedSlash = data === "/" && this.#editorFocused() && this.#options.isComposerEmpty?.();
			if (this.#matches(data, "lemon.palette.open") || typedSlash) {
				if (this.#options.openCommandPalette) {
					void this.#options.openCommandPalette(typedSlash ? "typed-slash" : "discovery");
					return { consume: true };
				}
			}
			if (this.#matches(data, "lemon.tasks.toggle")) {
				this.#options.toggleTaskTree?.();
				return { consume: true };
			}
			if (this.#matches(data, "lemon.omp.toggle")) {
				this.#options.toggleOmpPanel?.();
				return { consume: true };
			}
			if (this.#matches(data, "lemon.tools.toggle")) {
				this.#options.toggleToolOutputs?.();
				return { consume: true };
			}
			if (this.#matches(data, "lemon.tools.diff")) {
				this.#options.openDiff?.();
				return { consume: true };
			}
			if (this.#matches(data, "lemon.clipboard.copyLast")) {
				void this.#options.copyLastReply?.();
				return { consume: true };
			}
			if (this.#matches(data, "lemon.plan.toggle")) {
				void this.#options.togglePlan?.();
				return { consume: true };
			}
			if (this.#matches(data, "lemon.model.cycle")) {
				void this.#options.cycleModel?.();
				return { consume: true };
			}
			if (this.#matches(data, "lemon.picker.model")) {
				void this.#options.openModelPicker();
				return { consume: true };
			}
			if (this.#matches(data, "lemon.picker.thinking")) {
				void this.#options.openThinkingPicker?.();
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
			if (this.#matches(data, "lemon.transcript.toggleLatest")) {
				this.#options.toggleLatest?.();
				return { consume: true };
			}
			if (this.#matches(data, "lemon.transcript.cycleDetail")) {
				this.#options.cycleDetail?.();
				return { consume: true };
			}
			if (this.#matches(data, "lemon.editor.external")) {
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
