import { afterEach, describe, expect, test } from "bun:test";
import { Editor } from "@oh-my-pi/pi-tui/components/editor";
import { Markdown } from "@oh-my-pi/pi-tui/components/markdown";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import {
	DARK_PALETTE,
	detectSymbolPreset,
	getTheme,
	initTheme,
	peekTheme,
	resetTheme,
	Theme,
} from "../../src/ui/theme/theme.ts";
import {
	FALLBACK_SYMBOLS,
	getEditorTheme,
	getMarkdownTheme,
	getSelectListTheme,
	getSettingsListTheme,
	getSymbolTheme,
	invalidateThemeAdapters,
} from "../../src/ui/theme/tui-adapters.ts";

afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

describe("Theme", () => {
	test("initTheme installs a singleton that getTheme returns", () => {
		expect(peekTheme()).toBeUndefined();
		const theme = initTheme({ colorLevel: 3 });
		expect(getTheme()).toBe(theme);
		expect(peekTheme()).toBe(theme);
		expect(theme.name).toBe("lemon-dark");
	});

	test("getTheme lazily installs the dark default", () => {
		const theme = getTheme();
		expect(theme.appearance).toBe("dark");
		expect(theme.palette.accent).toBe(DARK_PALETTE.accent);
	});

	test("truecolor foreground wraps text in a 24-bit SGR pair", () => {
		const theme = new Theme({ colorLevel: 3 });
		const styled = theme.fg("accent", "lemon");
		expect(styled).toBe("\x1b[38;2;242;201;76mlemon\x1b[39m");
		expect(visibleWidth(styled)).toBe(5);
	});

	test("background colors are emitted even though chalk has no bgHex", () => {
		const theme = new Theme({ colorLevel: 3 });
		expect(theme.bg("selectedBg", "x")).toBe("\x1b[48;2;43;48;56mx\x1b[49m");
		const ansi256 = new Theme({ colorLevel: 2 });
		const esc = String.fromCharCode(27);
		expect(ansi256.bg("selectedBg", "x")).toMatch(new RegExp(`^${esc}\\[48;5;\\d+mx${esc}\\[49m$`));
	});

	test("color level 0 renders plain text", () => {
		const theme = new Theme({ colorLevel: 0 });
		expect(theme.fg("error", "boom")).toBe("boom");
		expect(theme.bg("selectedBg", "boom")).toBe("boom");
		expect(theme.getFgAnsi("error")).toBe("");
	});

	test("getFgAnsi returns the raw opening sequence for pi-natives", () => {
		const theme = new Theme({ colorLevel: 3 });
		expect(theme.getFgAnsi("syntaxKeyword")).toBe("\x1b[38;2;200;162;245m");
	});

	test("style functions are memoized per slot", () => {
		const theme = new Theme({ colorLevel: 3 });
		expect(theme.fgFn("accent")).toBe(theme.fgFn("accent"));
		expect(theme.bgFn("selectedBg")).toBe(theme.bgFn("selectedBg"));
	});

	test("the ascii preset swaps every glyph", () => {
		const theme = new Theme({ symbolPreset: "ascii" });
		expect(theme.cursor).toBe(">");
		expect(theme.boxRound.topLeft).toBe("+");
		expect(theme.hrChar).toBe("-");
		expect(theme.spinnerFrames).toEqual(["-", "\\", "|", "/"]);
	});

	test("symbol preset follows the locale", () => {
		expect(detectSymbolPreset({ LANG: "en_US.UTF-8" } as NodeJS.ProcessEnv)).toBe("unicode");
		expect(detectSymbolPreset({ LANG: "C" } as NodeJS.ProcessEnv)).toBe("ascii");
		expect(detectSymbolPreset({ LEMON_TUI_ASCII: "1" } as NodeJS.ProcessEnv)).toBe("ascii");
	});
});

describe("pi-tui adapters", () => {
	test("fall back to ASCII/plain text when no theme is installed", () => {
		expect(peekTheme()).toBeUndefined();
		expect(getSymbolTheme()).toBe(FALLBACK_SYMBOLS);
		expect(getMarkdownTheme().heading("Title")).toBe("Title");
		expect(getSelectListTheme().selectedText("row")).toBe("row");
		expect(getEditorTheme().borderColor("-")).toBe("-");
		expect(getSettingsListTheme().label("x", true, true)).toBe("x");
		// The guard's whole point: components construct without initTheme().
		expect(() => new Editor(getEditorTheme())).not.toThrow();
	});

	test("build styled themes once a theme is installed", () => {
		initTheme({ colorLevel: 3 });
		const symbols = getSymbolTheme();
		expect(symbols).not.toBe(FALLBACK_SYMBOLS);
		expect(symbols.cursor).toBe("❯");
		expect(getMarkdownTheme().heading("Title")).toContain("\x1b[38;2;242;201;76m");
		expect(getEditorTheme().selectList).toBe(getSelectListTheme());
	});

	test("adapters are memoized per theme instance", () => {
		initTheme({ colorLevel: 3 });
		const first = getMarkdownTheme();
		expect(getMarkdownTheme()).toBe(first);
		initTheme({ colorLevel: 3 });
		expect(getMarkdownTheme()).not.toBe(first);
	});

	test("a Markdown component renders within the requested width", () => {
		initTheme({ colorLevel: 3 });
		const md = new Markdown("# Hello\n\nsome **bold** text", 1, 0, getMarkdownTheme());
		const lines = md.render(40);
		expect(lines.length).toBeGreaterThan(0);
		for (const line of lines) expect(visibleWidth(line)).toBeLessThanOrEqual(40);
	});

	test("markdown code blocks highlight through pi-natives", () => {
		initTheme({ colorLevel: 3 });
		const highlighted = getMarkdownTheme().highlightCode?.("const x = 1;", "typescript");
		expect(highlighted).toBeDefined();
		expect(highlighted?.join("\n")).toContain("\x1b[");
	});
});
