/**
 * Theme: named color slots plus the glyph presets pi-tui components need.
 *
 * Two palettes (dark and light) keyed by slot; {@link "./appearance.ts"} decides
 * which one is installed and keeps it in step with the terminal.
 *
 * The installed {@link Theme} is a *stable* object: `/theme` swaps palettes
 * through {@link Theme.apply} rather than constructing a new instance, and every
 * style function this class hands out reads the palette at call time. That is
 * what makes a live switch recolor components which captured their theme
 * adapters at construction (the editor, most of all) instead of leaving them
 * painted in the old palette until they are rebuilt.
 *
 * Nothing here reaches for `process.stdout` at construction time except through
 * chalk's own level detection, so a Theme can be built in tests.
 */

import {
	Chalk,
	type ChalkInstance,
	type ColorLevel,
	supportsColor,
} from "@oh-my-pi/pi-utils/chalk";
import { hexToRgb } from "@oh-my-pi/pi-utils/color";

const ESC = "\x1b[";

/** 6x6x6 cube / grayscale ramp index, matching the standard xterm mapping. */
function rgbToAnsi256(r: number, g: number, b: number): number {
	if (r === g && g === b) {
		if (r < 8) return 16;
		if (r > 248) return 231;
		return Math.round(((r - 8) / 247) * 24) + 232;
	}
	return (
		16 + 36 * Math.round((r / 255) * 5) + 6 * Math.round((g / 255) * 5) + Math.round((b / 255) * 5)
	);
}

function rgbToBasicBg(r: number, g: number, b: number): number {
	const max = Math.max(r, g, b);
	if (max < 64) return 40;
	const bright = max > 170 ? 100 : 40;
	const bit = (channel: number) => (channel > max / 2 ? 1 : 0);
	return bright + (bit(r) | (bit(g) << 1) | (bit(b) << 2));
}

/** chalk has `hex()` but no `bgHex()`; this fills that gap at the same levels. */
function bgOpenSequence(hex: string, level: ColorLevel): string {
	if (level <= 0) return "";
	const { r, g, b } = hexToRgb(hex);
	if (level >= 3) return `${ESC}48;2;${r};${g};${b}m`;
	if (level === 2) return `${ESC}48;5;${rgbToAnsi256(r, g, b)}m`;
	return `${ESC}${rgbToBasicBg(r, g, b)}m`;
}

export type ColorSlot =
	// base text
	| "text"
	| "muted"
	| "dim"
	| "accent"
	| "success"
	| "warning"
	| "error"
	| "info"
	// chrome
	| "border"
	| "borderMuted"
	| "selectedBg"
	| "bannerTitle"
	| "bannerSubtitle"
	// transcript
	| "userPrefix"
	| "userText"
	| "assistantText"
	| "noticeText"
	// tools
	| "toolTitle"
	| "toolDetail"
	| "toolRunning"
	| "toolSuccess"
	| "toolError"
	| "toolDiffAdded"
	| "toolDiffRemoved"
	// status line
	| "statusLineText"
	| "statusLineGitDirty"
	// markdown
	| "mdHeading"
	| "mdLink"
	| "mdLinkUrl"
	| "mdCode"
	| "mdCodeBlock"
	| "mdCodeBlockBorder"
	| "mdQuote"
	| "mdQuoteBorder"
	| "mdHr"
	| "mdListBullet"
	// syntax highlighting
	| "syntaxComment"
	| "syntaxKeyword"
	| "syntaxFunction"
	| "syntaxVariable"
	| "syntaxString"
	| "syntaxNumber"
	| "syntaxType"
	| "syntaxOperator"
	| "syntaxPunctuation";

export type Palette = Record<ColorSlot, string>;

export type SymbolPreset = "unicode" | "ascii";

export interface BoxGlyphs {
	topLeft: string;
	topRight: string;
	bottomLeft: string;
	bottomRight: string;
	horizontal: string;
	vertical: string;
	teeDown: string;
	teeUp: string;
	teeLeft: string;
	teeRight: string;
	cross: string;
}

export interface ThemeOptions {
	name?: string;
	appearance?: "dark" | "light";
	palette?: Partial<Palette>;
	symbolPreset?: SymbolPreset;
	/** Overrides chalk's auto-detected color level (0 disables color). */
	colorLevel?: ColorLevel;
}

/** Lemon's dark palette. Lemon-yellow accent, cool neutrals. */
export const DARK_PALETTE: Palette = {
	text: "#e6e6e6",
	muted: "#9aa0a6",
	dim: "#6b7178",
	accent: "#f2c94c",
	success: "#7ec97e",
	warning: "#e8b64c",
	error: "#f07178",
	info: "#79b8ff",

	border: "#4a5058",
	borderMuted: "#3a3f46",
	selectedBg: "#2b3038",
	bannerTitle: "#f2c94c",
	bannerSubtitle: "#9aa0a6",

	userPrefix: "#79b8ff",
	userText: "#e6e6e6",
	assistantText: "#e6e6e6",
	noticeText: "#9aa0a6",

	toolTitle: "#c8a2f5",
	toolDetail: "#9aa0a6",
	toolRunning: "#f2c94c",
	toolSuccess: "#7ec97e",
	toolError: "#f07178",
	toolDiffAdded: "#7ec97e",
	toolDiffRemoved: "#f07178",

	statusLineText: "#9aa0a6",
	statusLineGitDirty: "#e8b64c",

	mdHeading: "#f2c94c",
	mdLink: "#79b8ff",
	mdLinkUrl: "#6b7178",
	mdCode: "#f2c94c",
	mdCodeBlock: "#c9d1d9",
	mdCodeBlockBorder: "#3a3f46",
	mdQuote: "#9aa0a6",
	mdQuoteBorder: "#4a5058",
	mdHr: "#3a3f46",
	mdListBullet: "#f2c94c",

	syntaxComment: "#6b7178",
	syntaxKeyword: "#c8a2f5",
	syntaxFunction: "#79b8ff",
	syntaxVariable: "#e6e6e6",
	syntaxString: "#7ec97e",
	syntaxNumber: "#e8b64c",
	syntaxType: "#5ecfcf",
	syntaxOperator: "#f2c94c",
	syntaxPunctuation: "#9aa0a6",
};

/**
 * Lemon's light palette. Same slot meanings, re-picked for a light background:
 * every foreground here clears 4.5:1 against a white-ish terminal, which the
 * dark palette's mid-greys do not.
 */
export const LIGHT_PALETTE: Palette = {
	text: "#1f2328",
	muted: "#57606a",
	dim: "#818b98",
	accent: "#9a6b00",
	success: "#1a7f37",
	warning: "#9a6700",
	error: "#cf222e",
	info: "#0969da",

	border: "#afb8c1",
	borderMuted: "#d0d7de",
	selectedBg: "#eaeef2",
	bannerTitle: "#9a6b00",
	bannerSubtitle: "#57606a",

	userPrefix: "#0969da",
	userText: "#1f2328",
	assistantText: "#1f2328",
	noticeText: "#57606a",

	toolTitle: "#8250df",
	toolDetail: "#57606a",
	toolRunning: "#9a6700",
	toolSuccess: "#1a7f37",
	toolError: "#cf222e",
	toolDiffAdded: "#1a7f37",
	toolDiffRemoved: "#cf222e",

	statusLineText: "#57606a",
	statusLineGitDirty: "#9a6700",

	mdHeading: "#9a6b00",
	mdLink: "#0969da",
	mdLinkUrl: "#818b98",
	mdCode: "#953800",
	mdCodeBlock: "#24292f",
	mdCodeBlockBorder: "#d0d7de",
	mdQuote: "#57606a",
	mdQuoteBorder: "#afb8c1",
	mdHr: "#d0d7de",
	mdListBullet: "#9a6b00",

	syntaxComment: "#6e7781",
	syntaxKeyword: "#cf222e",
	syntaxFunction: "#8250df",
	syntaxVariable: "#1f2328",
	syntaxString: "#0a3069",
	syntaxNumber: "#0550ae",
	syntaxType: "#953800",
	syntaxOperator: "#0550ae",
	syntaxPunctuation: "#57606a",
};

/** The palette an appearance defaults to when the caller names no overrides. */
export function paletteFor(appearance: "dark" | "light"): Palette {
	return appearance === "light" ? LIGHT_PALETTE : DARK_PALETTE;
}

/** The theme name an appearance defaults to (`/theme` prints it). */
export function themeNameFor(appearance: "dark" | "light"): string {
	return appearance === "light" ? "lemon-light" : "lemon-dark";
}

const UNICODE_BOX: BoxGlyphs = {
	topLeft: "┌",
	topRight: "┐",
	bottomLeft: "└",
	bottomRight: "┘",
	horizontal: "─",
	vertical: "│",
	teeDown: "┬",
	teeUp: "┴",
	teeLeft: "┤",
	teeRight: "├",
	cross: "┼",
};

const UNICODE_ROUND: BoxGlyphs = {
	...UNICODE_BOX,
	topLeft: "╭",
	topRight: "╮",
	bottomLeft: "╰",
	bottomRight: "╯",
};

export const ASCII_BOX: BoxGlyphs = {
	topLeft: "+",
	topRight: "+",
	bottomLeft: "+",
	bottomRight: "+",
	horizontal: "-",
	vertical: "|",
	teeDown: "+",
	teeUp: "+",
	teeLeft: "+",
	teeRight: "+",
	cross: "+",
};

export class Theme {
	name: string;
	appearance: "dark" | "light";
	palette: Palette;

	readonly #chalk: ChalkInstance;
	readonly #symbolPreset: SymbolPreset;
	readonly #fgCache = new Map<ColorSlot, (text: string) => string>();
	readonly #bgCache = new Map<ColorSlot, (text: string) => string>();
	readonly #bgOpenCache = new Map<ColorSlot, string>();
	readonly #ansiCache = new Map<ColorSlot, string>();

	constructor(options: ThemeOptions = {}) {
		this.appearance = options.appearance ?? "dark";
		this.name = options.name ?? themeNameFor(this.appearance);
		this.palette = { ...paletteFor(this.appearance), ...(options.palette ?? {}) };
		this.#symbolPreset = options.symbolPreset ?? detectSymbolPreset();
		this.#chalk = new Chalk({
			level: options.colorLevel ?? (supportsColor ? supportsColor.level : 0),
		});
	}

	/**
	 * Swap the palette in place. The style functions already handed out keep
	 * working and start painting in the new colors, which is what lets `/theme`
	 * recolor long-lived components (the editor) without rebuilding them. Callers
	 * must still invalidate the theme adapters and force a full redraw — cached
	 * *rows* elsewhere are not this class's business.
	 */
	apply(options: Pick<ThemeOptions, "name" | "appearance" | "palette"> = {}): this {
		this.appearance = options.appearance ?? this.appearance;
		this.name = options.name ?? themeNameFor(this.appearance);
		this.palette = { ...paletteFor(this.appearance), ...(options.palette ?? {}) };
		// Only derived byte sequences are dropped; the closures that read them
		// stay valid, which is the point of applying in place.
		this.#bgOpenCache.clear();
		this.#ansiCache.clear();
		return this;
	}

	get colorLevel(): ColorLevel {
		return this.#chalk.level;
	}

	getSymbolPreset(): SymbolPreset {
		return this.#symbolPreset;
	}

	getColorHex(slot: ColorSlot): string {
		return this.palette[slot];
	}

	/**
	 * Style function for a slot (memoized, safe to hand to pi-tui themes).
	 * The hex is read on every call so a palette swap reaches functions that were
	 * handed out before it.
	 */
	fgFn(slot: ColorSlot): (text: string) => string {
		let fn = this.#fgCache.get(slot);
		if (!fn) {
			fn = (text: string) => this.#chalk.hex(this.palette[slot])(text);
			this.#fgCache.set(slot, fn);
		}
		return fn;
	}

	bgFn(slot: ColorSlot): (text: string) => string {
		let fn = this.#bgCache.get(slot);
		if (!fn) {
			fn = (text: string) => {
				const open = this.#bgOpen(slot);
				return open ? `${open}${text}${ESC}49m` : text;
			};
			this.#bgCache.set(slot, fn);
		}
		return fn;
	}

	/** The background opening sequence for a slot, recomputed after `apply`. */
	#bgOpen(slot: ColorSlot): string {
		let open = this.#bgOpenCache.get(slot);
		if (open === undefined) {
			open = bgOpenSequence(this.palette[slot], this.#chalk.level);
			this.#bgOpenCache.set(slot, open);
		}
		return open;
	}

	fg(slot: ColorSlot, text: string): string {
		return this.fgFn(slot)(text);
	}

	bg(slot: ColorSlot, text: string): string {
		return this.bgFn(slot)(text);
	}

	/**
	 * Foreground in an arbitrary hex color, downsampled to the terminal's color
	 * level like the palette slots. For artwork (the banner logo) whose colors
	 * are not semantic slots.
	 */
	hex(color: string, text: string): string {
		return this.#chalk.hex(color)(text);
	}

	/** Background counterpart of {@link hex}; returns `text` unstyled without color. */
	hexBg(color: string, text: string): string {
		const open = bgOpenSequence(color, this.#chalk.level);
		return open ? `${open}${text}${ESC}49m` : text;
	}

	/**
	 * Raw ANSI opening sequence for a slot — pi-natives' syntax highlighter takes
	 * colors as escape strings rather than functions.
	 */
	getFgAnsi(slot: ColorSlot): string {
		let ansi = this.#ansiCache.get(slot);
		if (ansi === undefined) {
			const marker = " ";
			const styled = this.fg(slot, marker);
			ansi = styled.slice(0, styled.indexOf(marker));
			this.#ansiCache.set(slot, ansi);
		}
		return ansi;
	}

	bold(text: string): string {
		return this.#chalk.bold(text);
	}

	italic(text: string): string {
		return this.#chalk.italic(text);
	}

	underline(text: string): string {
		return this.#chalk.underline(text);
	}

	strikethrough(text: string): string {
		return this.#chalk.strikethrough(text);
	}

	/**
	 * Swap foreground and background. Additive (it keeps whatever colour is
	 * already applied), which is what the word-level diff needs to mark the
	 * changed run inside an already-red or already-green line.
	 */
	inverse(text: string): string {
		return this.#chalk.inverse(text);
	}

	get boxRound(): BoxGlyphs {
		return this.#symbolPreset === "ascii" ? ASCII_BOX : UNICODE_ROUND;
	}

	get boxSharp(): BoxGlyphs {
		return this.#symbolPreset === "ascii" ? ASCII_BOX : UNICODE_BOX;
	}

	get cursor(): string {
		return this.#symbolPreset === "ascii" ? ">" : "❯";
	}

	get inputCursor(): string {
		return this.#symbolPreset === "ascii" ? "|" : "▏";
	}

	get quoteBorder(): string {
		return this.#symbolPreset === "ascii" ? "|" : "│";
	}

	get hrChar(): string {
		return this.#symbolPreset === "ascii" ? "-" : "─";
	}

	get bullet(): string {
		return this.#symbolPreset === "ascii" ? "*" : "•";
	}

	get spinnerFrames(): string[] {
		return this.#symbolPreset === "ascii"
			? ["-", "\\", "|", "/"]
			: ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
	}
}

/** Terminals without a UTF-8 locale get the ASCII glyph preset. */
export function detectSymbolPreset(env: NodeJS.ProcessEnv = process.env): SymbolPreset {
	if (env.LEMON_TUI_ASCII === "1") return "ascii";
	const locale = env.LC_ALL || env.LC_CTYPE || env.LANG || "";
	if (locale && !/utf-?8/i.test(locale)) return "ascii";
	return "unicode";
}

let activeTheme: Theme | undefined;

/**
 * Install the process-wide theme. Call this before constructing any pi-tui
 * component: they take their theme by constructor argument and pi-tui ships no
 * defaults.
 */
export function initTheme(options: ThemeOptions = {}): Theme {
	activeTheme = new Theme(options);
	return activeTheme;
}

/** The active theme, installing the dark default if `initTheme` never ran. */
export function getTheme(): Theme {
	if (!activeTheme) activeTheme = new Theme();
	return activeTheme;
}

/** The active theme, or undefined — for adapters that must not install one. */
export function peekTheme(): Theme | undefined {
	return activeTheme;
}

/** Test/`/theme` hook: drop the installed theme. */
export function resetTheme(): void {
	activeTheme = undefined;
}
