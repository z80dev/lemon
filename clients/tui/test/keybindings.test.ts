import { describe, expect, test } from "bun:test";
import { KeybindingsManager, TUI_KEYBINDINGS } from "@oh-my-pi/pi-tui/keybindings";
import { TUI } from "@oh-my-pi/pi-tui/tui";
import { resolveKeybindings } from "../src/config.ts";
import { InputController, LEMON_KEYBINDINGS } from "../src/ui/controllers/input-controller.ts";
import { MemoryTerminal } from "./helpers/memory-terminal.ts";

const definitions = { ...TUI_KEYBINDINGS, ...LEMON_KEYBINDINGS };

describe("[tui.keys]", () => {
	test("absent table leaves every existing default unchanged and new actions unbound", () => {
		const { manager, issues } = resolveKeybindings(undefined, definitions);
		expect(issues).toEqual([]);
		expect(manager.getResolvedBindings()).toEqual(
			new KeybindingsManager(definitions).getResolvedBindings(),
		);
		expect(manager.getKeys("lemon.plan.toggle" as never)).toEqual([]);
		expect(manager.getKeys("lemon.model.cycle" as never)).toEqual([]);
	});

	test("single and multiple keys replace, rather than append to, defaults", () => {
		const { manager, issues } = resolveKeybindings(
			{
				"lemon.palette.open": "alt+p",
				"lemon.picker.model": ["alt+shift+m", "ctrl+shift+m"],
			},
			definitions,
		);
		expect(issues).toEqual([]);
		expect(manager.matches("\x1bp", "lemon.palette.open" as never)).toBe(true);
		expect(manager.matches("\x10", "lemon.palette.open" as never)).toBe(false);
		expect(manager.getKeys("lemon.picker.model" as never)).toEqual(["shift+alt+m", "ctrl+shift+m"]);
	});

	test("empty arrays and none unbind", () => {
		const { manager, issues } = resolveKeybindings(
			{
				"lemon.palette.open": [],
				"lemon.picker.model": "none",
			},
			definitions,
		);
		expect(issues).toEqual([]);
		expect(manager.getKeys("lemon.palette.open" as never)).toEqual([]);
		expect(manager.getKeys("lemon.picker.model" as never)).toEqual([]);
	});

	test("unknown actions and malformed keys are ignored together", () => {
		const { manager, issues } = resolveKeybindings(
			{
				"lemon.noSuchAction": "alt+p",
				"lemon.palette.open": "ctrl+not-a-key",
				"lemon.picker.model": ["alt+v", 42],
				"lemon.plan.toggle": "ctrl+ctrl+p",
			},
			definitions,
		);
		expect(issues).toHaveLength(4);
		expect(issues.join("; ")).toContain("unknown action lemon.noSuchAction");
		expect(issues.join("; ")).toContain("invalid key for lemon.palette.open");
		expect(manager.getKeys("lemon.palette.open" as never)).toEqual(["ctrl+p"]);
		expect(manager.getKeys("lemon.picker.model" as never)).toEqual(["ctrl+o"]);
	});

	test.each([false, 7, "alt+p", []].map((configured) => ({ configured })))(
		"invalid table %j never throws",
		({ configured }) => {
			const { issues } = resolveKeybindings(configured, definitions);
			expect(issues).toEqual(["[tui.keys] must be a table"]);
		},
	);

	test("conflicting user bindings, including modifier aliases, are rejected", () => {
		const { manager, issues } = resolveKeybindings(
			{
				"lemon.plan.toggle": "alt+shift+p",
				"lemon.model.cycle": "shift+alt+p",
			},
			definitions,
		);
		expect(issues.join("; ")).toContain("conflicts");
		expect(manager.getKeys("lemon.plan.toggle" as never)).toEqual([]);
		expect(manager.getKeys("lemon.model.cycle" as never)).toEqual([]);
	});

	test("shifted punctuation aliases cannot claim the same input", () => {
		const { manager, issues } = resolveKeybindings(
			{
				"lemon.plan.toggle": "!",
				"lemon.model.cycle": "shift+!",
			},
			definitions,
		);
		expect(issues.join("; ")).toContain("conflicts");
		expect(manager.getKeys("lemon.plan.toggle" as never)).toEqual([]);
		expect(manager.getKeys("lemon.model.cycle" as never)).toEqual([]);
	});

	test("conflicts with unchanged defaults reject only the override", () => {
		const { manager, issues } = resolveKeybindings({ "lemon.plan.toggle": "ctrl+p" }, definitions);
		expect(issues.join("; ")).toContain("lemon.palette.open");
		expect(manager.getKeys("lemon.plan.toggle" as never)).toEqual([]);
		expect(manager.getKeys("lemon.palette.open" as never)).toEqual(["ctrl+p"]);
	});

	test("unbinding the original owner allows reassignment", () => {
		const { manager, issues } = resolveKeybindings(
			{
				"lemon.palette.open": "none",
				"lemon.plan.toggle": "ctrl+p",
			},
			definitions,
		);
		expect(issues).toEqual([]);
		expect(manager.matches("\x10", "lemon.plan.toggle" as never)).toBe(true);
	});

	test("fallback defaults cannot leave a second conflicting override active", () => {
		const { manager, issues } = resolveKeybindings(
			{
				"lemon.palette.open": "alt+v",
				"lemon.picker.model": "alt+v",
				"lemon.plan.toggle": "ctrl+p",
			},
			definitions,
		);
		expect(issues.join("; ")).toContain("ctrl+p conflicts");
		expect(manager.getKeys("lemon.plan.toggle" as never)).toEqual([]);
	});

	test("new actions dispatch when bound and defer to overlays; startup issues use one notice", () => {
		const terminal = new MemoryTerminal();
		const tui = new TUI(terminal);
		let overlay = false;
		let plans = 0;
		let models = 0;
		const notices: string[] = [];
		const input = new InputController({
			tui,
			hasOverlay: () => overlay,
			openModelPicker: () => {},
			userBindings: {
				"lemon.plan.toggle": "alt+p",
				"lemon.model.cycle": "alt+v",
				"lemon.invalid": "foo",
				"lemon.queue.focus": "invalid",
				"lemon.picker.model": "ctrl+p",
			},
			togglePlan: () => {
				plans += 1;
			},
			cycleModel: () => {
				models += 1;
			},
			notice: (text) => notices.push(text),
		});
		expect(notices).toHaveLength(1);
		expect(notices[0]).toContain("unknown action");
		expect(notices[0]).toContain("invalid key");
		expect(notices[0]).toContain("conflicts");
		input.attach();
		tui.start();
		try {
			terminal.sendInput("\x1bp");
			terminal.sendInput("\x1bv");
			expect([plans, models]).toEqual([1, 1]);
			overlay = true;
			terminal.sendInput("\x1bp");
			terminal.sendInput("\x1bv");
			expect([plans, models]).toEqual([1, 1]);
			expect(input.describe().join("\n")).toContain("alt+p — Toggle plan mode");
		} finally {
			input.dispose();
			tui.stop();
		}
	});
});
