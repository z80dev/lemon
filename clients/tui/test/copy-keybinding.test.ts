import { expect, test } from "bun:test";
import { TUI_KEYBINDINGS } from "@oh-my-pi/pi-tui/keybindings";
import { TUI } from "@oh-my-pi/pi-tui/tui";
import { InputController, LEMON_KEYBINDINGS } from "../src/ui/controllers/input-controller.ts";
import { MemoryTerminal } from "./helpers/memory-terminal.ts";

test("Alt+Shift+C copies without an existing binding conflict and defers to overlays", () => {
	const terminal = new MemoryTerminal();
	const tui = new TUI(terminal);
	let copied = 0;
	let overlay = false;
	const input = new InputController({
		tui,
		hasOverlay: () => overlay,
		openModelPicker: () => {},
		copyLastReply: () => {
			copied += 1;
		},
	});
	for (const [name, definition] of Object.entries({ ...TUI_KEYBINDINGS, ...LEMON_KEYBINDINGS })) {
		if (name === "lemon.clipboard.copyLast") continue;
		expect([definition.defaultKeys].flat()).not.toContain("alt+shift+c");
	}
	input.attach();
	tui.start();
	try {
		terminal.sendInput("\x1b[99;4u");
		expect(copied).toBe(1);
		overlay = true;
		terminal.sendInput("\x1b[99;4u");
		expect(copied).toBe(1);
		expect(input.describe().join("\n")).toContain("alt+shift+c — Copy the last assistant reply");
	} finally {
		input.dispose();
		tui.stop();
	}
});
