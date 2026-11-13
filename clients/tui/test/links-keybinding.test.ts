import { expect, test } from "bun:test";
import { TUI_KEYBINDINGS } from "@oh-my-pi/pi-tui/keybindings";
import { TUI } from "@oh-my-pi/pi-tui/tui";
import { InputController, LEMON_KEYBINDINGS } from "../src/ui/controllers/input-controller.ts";
import { MemoryTerminal } from "./helpers/memory-terminal.ts";

test("Alt+L opens the link browser without a binding conflict and defers to overlays", () => {
	const terminal = new MemoryTerminal();
	const tui = new TUI(terminal);
	let opened = 0;
	let overlay = false;
	const input = new InputController({
		tui,
		hasOverlay: () => overlay,
		openModelPicker: () => {},
		openLinkBrowser: () => {
			opened += 1;
		},
	});
	for (const [name, definition] of Object.entries({ ...TUI_KEYBINDINGS, ...LEMON_KEYBINDINGS })) {
		if (name === "lemon.links.browse") continue;
		expect([definition.defaultKeys].flat()).not.toContain("alt+l");
	}
	input.attach();
	tui.start();
	try {
		terminal.sendInput("\x1bl");
		expect(opened).toBe(1);
		overlay = true;
		terminal.sendInput("\x1bl");
		expect(opened).toBe(1);
		expect(input.describe().join("\n")).toContain("alt+l — Browse the transcript's links");
	} finally {
		input.dispose();
		tui.stop();
	}
});

test("[tui.keys] rebinds the link browser", () => {
	const terminal = new MemoryTerminal();
	const tui = new TUI(terminal);
	let opened = 0;
	const input = new InputController({
		tui,
		userBindings: { "lemon.links.browse": "alt+k" },
		hasOverlay: () => false,
		openModelPicker: () => {},
		openLinkBrowser: () => {
			opened += 1;
		},
	});
	input.attach();
	tui.start();
	try {
		terminal.sendInput("\x1bl");
		expect(opened).toBe(0);
		terminal.sendInput("\x1bk");
		expect(opened).toBe(1);
	} finally {
		input.dispose();
		tui.stop();
	}
});
