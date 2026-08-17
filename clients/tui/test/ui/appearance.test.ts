import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { TerminalAppearance } from "@oh-my-pi/pi-tui/terminal";
import { AssistantMessageComponent } from "../../src/ui/components/assistant-message.ts";
import { PickerOverlay } from "../../src/ui/components/pickers.ts";
import { renderStatusLine } from "../../src/ui/components/status-bar.ts";
import {
	AppearanceController,
	initAppearanceTheme,
	installAppearance,
	normalizePreference,
	resolveAppearance,
	resolvePreference,
	THEME_ENV_VAR,
} from "../../src/ui/theme/appearance.ts";
import {
	DARK_PALETTE,
	getTheme,
	initTheme,
	LIGHT_PALETTE,
	peekTheme,
	resetTheme,
} from "../../src/ui/theme/theme.ts";
import { getEditorTheme, invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { stripAnsi } from "../helpers/memory-terminal.ts";

beforeEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

/** A terminal that reports whatever the test tells it to, when it likes. */
class StubTerminal {
	appearance: TerminalAppearance | undefined;
	#callbacks: Array<(appearance: TerminalAppearance) => void> = [];

	constructor(appearance?: TerminalAppearance) {
		this.appearance = appearance;
	}

	onAppearanceChange(callback: (appearance: TerminalAppearance) => void): void {
		this.#callbacks.push(callback);
		// pi-tui replays an already-detected appearance to late subscribers.
		if (this.appearance) callback(this.appearance);
	}

	/** The OSC 11 answer arriving after startup. */
	emit(appearance: TerminalAppearance): void {
		this.appearance = appearance;
		for (const callback of this.#callbacks) callback(appearance);
	}
}

describe("normalizePreference", () => {
	test("accepts the words and the palette names, case-insensitively", () => {
		expect(normalizePreference("light")).toBe("light");
		expect(normalizePreference("LEMON-LIGHT")).toBe("light");
		expect(normalizePreference(" dark ")).toBe("dark");
		expect(normalizePreference("lemon-dark")).toBe("dark");
		expect(normalizePreference("system")).toBe("auto");
	});

	test("rejects anything else so a typo is reported rather than guessed", () => {
		expect(normalizePreference("solarized")).toBeUndefined();
		expect(normalizePreference("")).toBeUndefined();
		expect(normalizePreference(undefined)).toBeUndefined();
	});
});

describe("preference precedence", () => {
	test("env beats config beats the auto default", () => {
		expect(resolvePreference({ env: { [THEME_ENV_VAR]: "light" }, configured: "dark" })).toEqual({
			preference: "light",
			source: "env",
		});
		expect(resolvePreference({ env: {}, configured: "dark" })).toEqual({
			preference: "dark",
			source: "config",
		});
		expect(resolvePreference({ env: {} })).toEqual({ preference: "auto", source: "default" });
	});

	test("an unreadable env value falls through to the config rather than failing", () => {
		expect(
			resolvePreference({ env: { [THEME_ENV_VAR]: "chartreuse" }, configured: "light" }),
		).toEqual({ preference: "light", source: "config" });
	});
});

describe("resolveAppearance", () => {
	test("auto takes the terminal's report", () => {
		expect(resolveAppearance({ env: {}, terminalAppearance: "light" })).toEqual({
			preference: "auto",
			appearance: "light",
			source: "terminal",
		});
	});

	test("auto with no report yet is dark", () => {
		expect(resolveAppearance({ env: {} })).toEqual({
			preference: "auto",
			appearance: "dark",
			source: "default",
		});
	});

	test("an explicit preference ignores the terminal", () => {
		expect(
			resolveAppearance({ env: { [THEME_ENV_VAR]: "dark" }, terminalAppearance: "light" }),
		).toEqual({ preference: "dark", appearance: "dark", source: "env" });
	});

	test("`auto` in the config still means the terminal decides", () => {
		expect(resolveAppearance({ env: {}, configured: "auto", terminalAppearance: "light" })).toEqual(
			{
				preference: "auto",
				appearance: "light",
				source: "terminal",
			},
		);
	});
});

describe("installAppearance", () => {
	test("installs the light palette under the light name", () => {
		initTheme({ colorLevel: 3 });
		installAppearance("light");
		const theme = getTheme();
		expect(theme.appearance).toBe("light");
		expect(theme.name).toBe("lemon-light");
		expect(theme.getColorHex("text")).toBe(LIGHT_PALETTE.text);
	});

	test("mutates the installed theme rather than replacing it", () => {
		const before = initTheme({ colorLevel: 3 });
		installAppearance("light");
		expect(peekTheme()).toBe(before);
	});

	test("style functions handed out before the swap paint in the new palette", () => {
		initTheme({ colorLevel: 3 });
		// The editor captures its theme adapter at construction and never asks
		// again, so this is exactly the guarantee a live `/theme` switch rests on.
		const editorTheme = getEditorTheme();
		const darkBorder = editorTheme.borderColor("│");

		installAppearance("light");

		const lightBorder = editorTheme.borderColor("│");
		expect(lightBorder).not.toBe(darkBorder);
		expect(lightBorder).toContain(hexAnsi(LIGHT_PALETTE.borderMuted));
	});

	test("switching back restores the dark bytes exactly", () => {
		initTheme({ colorLevel: 3 });
		const dark = getTheme().fg("accent", "x");
		installAppearance("light");
		installAppearance("dark");
		expect(getTheme().fg("accent", "x")).toBe(dark);
		expect(getTheme().getColorHex("accent")).toBe(DARK_PALETTE.accent);
	});

	test("background sequences follow the swap too", () => {
		initTheme({ colorLevel: 3 });
		const selected = getTheme().bgFn("selectedBg");
		const dark = selected("row");
		installAppearance("light");
		expect(selected("row")).not.toBe(dark);
	});
});

describe("initAppearanceTheme", () => {
	test("installs what it resolved and reports it", () => {
		const resolution = initAppearanceTheme({ env: {}, configured: "light", colorLevel: 3 });
		expect(resolution).toEqual({ preference: "light", appearance: "light", source: "config" });
		expect(getTheme().appearance).toBe("light");
	});
});

describe("AppearanceController", () => {
	test("auto follows the terminal, including a report that lands after start", () => {
		initTheme({ colorLevel: 3 });
		const terminal = new StubTerminal();
		const changes: string[] = [];
		const controller = new AppearanceController({
			terminal,
			preference: "auto",
			onChange: (appearance) => changes.push(appearance),
		});

		controller.start();
		expect(getTheme().appearance).toBe("dark");

		terminal.emit("light");

		expect(controller.appearance).toBe("light");
		expect(getTheme().appearance).toBe("light");
		expect(changes).toEqual(["light"]);
	});

	test("a report matching what is installed changes nothing", () => {
		initTheme({ colorLevel: 3 });
		const terminal = new StubTerminal("dark");
		const changes: string[] = [];
		const controller = new AppearanceController({
			terminal,
			preference: "auto",
			onChange: (appearance) => changes.push(appearance),
		});

		controller.start();
		terminal.emit("dark");

		expect(changes).toEqual([]);
	});

	test("an explicit preference is not overridden by the terminal", () => {
		initTheme({ colorLevel: 3 });
		const terminal = new StubTerminal("light");
		const controller = new AppearanceController({ terminal, preference: "dark" });

		controller.start();
		terminal.emit("light");

		expect(controller.appearance).toBe("dark");
		expect(getTheme().appearance).toBe("dark");
		// The report is still remembered, so switching to auto later is instant.
		expect(controller.reported).toBe("light");
	});

	test("switching to auto adopts the report the terminal already made", () => {
		initTheme({ colorLevel: 3 });
		const terminal = new StubTerminal("light");
		const controller = new AppearanceController({ terminal, preference: "dark" });
		controller.start();

		expect(controller.setPreference("auto")).toBe("light");
		expect(getTheme().appearance).toBe("light");
	});

	test("works without a terminal at all", () => {
		initTheme({ colorLevel: 3 });
		const controller = new AppearanceController({ preference: "light" });
		controller.start();
		expect(getTheme().appearance).toBe("light");
		expect(controller.setPreference("auto")).toBe("dark");
	});
});

describe("components under the light palette", () => {
	test("the status line, a picker and a transcript block all render in it", () => {
		initAppearanceTheme({ env: { [THEME_ENV_VAR]: "light" }, colorLevel: 3 });

		const status = renderStatusLine(
			{
				sessionKey: "tui-a",
				model: "claude-sonnet-4",
				contextTokens: 1000,
				contextWindow: 200_000,
				sessionCount: 2,
				busy: false,
				busySessions: 0,
				unread: 0,
				approvals: 0,
				connection: "online",
				mode: "queue",
				queued: 0,
			},
			80,
		);
		const picker = new PickerOverlay({
			title: "sessions",
			items: [{ value: "tui-a", label: "tui-a", description: "current" }],
			onSelect: () => {},
		});
		const message = new AssistantMessageComponent("**bold** and `code`");

		const rows = [status, ...picker.render(60), ...message.render(60)].join("\n");
		expect(stripAnsi(rows)).toContain("tui-a");
		// Painted with the light palette's ink, not the dark palette's.
		expect(rows).toContain(hexAnsi(LIGHT_PALETTE.accent));
		expect(rows).not.toContain(hexAnsi(DARK_PALETTE.accent));
	});
});

/** The ANSI truecolor opening sequence chalk emits for a hex color. */
function hexAnsi(hex: string): string {
	const value = Number.parseInt(hex.slice(1), 16);
	return `38;2;${(value >> 16) & 0xff};${(value >> 8) & 0xff};${value & 0xff}`;
}
