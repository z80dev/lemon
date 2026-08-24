/**
 * Adapters from our {@link Theme} to the theme interfaces pi-tui components
 * take by constructor argument (pi-tui ships no defaults — a component built
 * with an undefined theme crashes on first render).
 *
 * Every getter tolerates a missing theme and falls back to plain text plus the
 * ASCII glyph preset. That guard is what lets a component be constructed in a
 * test, or from a module instance that never ran `initTheme()`, without
 * exploding — the same failure omp hit in their issue #2998.
 */

import { highlightCode as nativeHighlightCode, supportsLanguage } from "@oh-my-pi/pi-natives";
import type {
	EditorTheme,
	MarkdownTheme,
	SelectListTheme,
	SettingsListTheme,
	SymbolTheme,
} from "@oh-my-pi/pi-tui";
import { ASCII_BOX, peekTheme, type Theme } from "./theme.ts";

const identity = (text: string) => text;

/** Glyphs used when no theme is installed. */
export const FALLBACK_SYMBOLS: SymbolTheme = {
	cursor: ">",
	inputCursor: "|",
	boxRound: ASCII_BOX,
	boxSharp: ASCII_BOX,
	table: ASCII_BOX,
	quoteBorder: "|",
	hrChar: "-",
	spinnerFrames: ["-", "\\", "|", "/"],
};

interface AdapterCache {
	theme: Theme | undefined;
	symbols?: SymbolTheme;
	markdown?: MarkdownTheme;
	selectList?: SelectListTheme;
	editor?: EditorTheme;
	settingsList?: SettingsListTheme;
}

let cache: AdapterCache = { theme: undefined };

function cacheFor(theme: Theme | undefined): AdapterCache {
	if (cache.theme !== theme) cache = { theme };
	return cache;
}

/** Drop memoized adapters (call after switching themes). */
export function invalidateThemeAdapters(): void {
	cache = { theme: undefined };
}

export function getSymbolTheme(): SymbolTheme {
	const theme = peekTheme();
	if (!theme) return FALLBACK_SYMBOLS;
	const entry = cacheFor(theme);
	if (!entry.symbols) {
		entry.symbols = {
			cursor: theme.cursor,
			inputCursor: theme.inputCursor,
			boxRound: theme.boxRound,
			boxSharp: theme.boxSharp,
			table: theme.boxSharp,
			quoteBorder: theme.quoteBorder,
			hrChar: theme.hrChar,
			spinnerFrames: theme.spinnerFrames,
		};
	}
	return entry.symbols;
}

/**
 * Syntax highlighting through pi-natives. Returns null when the tokenizer
 * throws so callers can fall back to flat code styling.
 */
export function highlightWithTheme(
	code: string,
	lang: string | undefined,
	theme: Theme,
): string | null {
	const validLang = lang && supportsLanguage(lang) ? lang : undefined;
	try {
		return nativeHighlightCode(code, validLang, {
			comment: theme.getFgAnsi("syntaxComment"),
			keyword: theme.getFgAnsi("syntaxKeyword"),
			function: theme.getFgAnsi("syntaxFunction"),
			variable: theme.getFgAnsi("syntaxVariable"),
			string: theme.getFgAnsi("syntaxString"),
			number: theme.getFgAnsi("syntaxNumber"),
			type: theme.getFgAnsi("syntaxType"),
			operator: theme.getFgAnsi("syntaxOperator"),
			punctuation: theme.getFgAnsi("syntaxPunctuation"),
			inserted: theme.getFgAnsi("toolDiffAdded"),
			deleted: theme.getFgAnsi("toolDiffRemoved"),
		});
	} catch {
		return null;
	}
}

export function getMarkdownTheme(): MarkdownTheme {
	const theme = peekTheme();
	if (!theme) {
		return {
			heading: identity,
			link: identity,
			linkUrl: identity,
			code: identity,
			codeBlock: identity,
			codeBlockBorder: identity,
			quote: identity,
			quoteBorder: identity,
			hr: identity,
			listBullet: identity,
			bold: identity,
			italic: identity,
			strikethrough: identity,
			underline: identity,
			symbols: FALLBACK_SYMBOLS,
		};
	}
	const entry = cacheFor(theme);
	if (!entry.markdown) {
		entry.markdown = {
			heading: theme.fgFn("mdHeading"),
			link: theme.fgFn("mdLink"),
			linkUrl: theme.fgFn("mdLinkUrl"),
			code: theme.fgFn("mdCode"),
			codeBlock: theme.fgFn("mdCodeBlock"),
			codeBlockBorder: theme.fgFn("mdCodeBlockBorder"),
			quote: theme.fgFn("mdQuote"),
			quoteBorder: theme.fgFn("mdQuoteBorder"),
			hr: theme.fgFn("mdHr"),
			listBullet: theme.fgFn("mdListBullet"),
			bold: (text) => theme.bold(text),
			italic: (text) => theme.italic(text),
			strikethrough: (text) => theme.strikethrough(text),
			underline: (text) => theme.underline(text),
			symbols: getSymbolTheme(),
			highlightCode: (code: string, lang?: string): string[] => {
				const highlighted = highlightWithTheme(code, lang, theme);
				if (highlighted !== null) return highlighted.split("\n");
				return code.split("\n").map((line) => theme.fg("mdCodeBlock", line));
			},
		};
	}
	return entry.markdown;
}

export function getSelectListTheme(): SelectListTheme {
	const theme = peekTheme();
	if (!theme) {
		return {
			selectedPrefix: identity,
			selectedText: identity,
			description: identity,
			scrollInfo: identity,
			noMatch: identity,
			symbols: FALLBACK_SYMBOLS,
			hovered: identity,
		};
	}
	const entry = cacheFor(theme);
	if (!entry.selectList) {
		entry.selectList = {
			selectedPrefix: theme.fgFn("accent"),
			selectedText: theme.fgFn("accent"),
			description: theme.fgFn("muted"),
			scrollInfo: theme.fgFn("muted"),
			noMatch: theme.fgFn("muted"),
			symbols: getSymbolTheme(),
			hovered: theme.bgFn("selectedBg"),
		};
	}
	return entry.selectList;
}

export function getEditorTheme(): EditorTheme {
	const theme = peekTheme();
	if (!theme) {
		return {
			borderColor: identity,
			selectList: getSelectListTheme(),
			symbols: FALLBACK_SYMBOLS,
			hintStyle: identity,
		};
	}
	const entry = cacheFor(theme);
	if (!entry.editor) {
		entry.editor = {
			borderColor: theme.fgFn("borderMuted"),
			selectList: getSelectListTheme(),
			symbols: getSymbolTheme(),
			hintStyle: theme.fgFn("dim"),
		};
	}
	return entry.editor;
}

export function getSettingsListTheme(): SettingsListTheme {
	const theme = peekTheme();
	if (!theme) {
		return {
			label: identity,
			value: identity,
			description: identity,
			cursor: "> ",
			hint: identity,
			heading: identity,
			section: identity,
			hovered: identity,
		};
	}
	const entry = cacheFor(theme);
	if (!entry.settingsList) {
		entry.settingsList = {
			label: (text, selected, changed) =>
				changed
					? theme.fg("statusLineGitDirty", text)
					: selected
						? theme.fg("accent", text)
						: theme.fg("text", text),
			value: (text, selected, changed) =>
				changed
					? theme.fg("statusLineGitDirty", text)
					: selected
						? theme.fg("accent", text)
						: theme.fg("muted", text),
			description: theme.fgFn("dim"),
			cursor: theme.fg("accent", `${theme.cursor} `),
			hint: theme.fgFn("dim"),
			heading: (text, dimmed) =>
				dimmed
					? theme.fg("dim", theme.underline(text))
					: theme.fg("muted", theme.bold(theme.underline(text))),
			section: (text, active) =>
				active ? theme.fg("accent", theme.bold(text)) : theme.fg("muted", text),
			hovered: theme.bgFn("selectedBg"),
		};
	}
	return entry.settingsList;
}
