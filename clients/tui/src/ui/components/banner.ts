/**
 * Startup banner: a pixel-art lemon beside a half-block wordmark and key hints.
 *
 * The mark is a grid of square pixels, two per cell as `▀ ▄ █` half-blocks with
 * a per-cell foreground (plus a background where a cell's halves differ), so
 * every UTF-8 terminal font draws it. Terminals on the ASCII glyph preset, and
 * frames too narrow for logo plus text, get the single-line banner instead.
 * On startup a highlight sweeps once across the mark; while it plays the banner
 * reports itself unfinalized so no intermediate frame retires to scrollback.
 *
 * A TSP terminal gets the shared welcome card instead (`omp.welcome`): the
 * same pixels drawn as an SVG image beside the wordmark and version, then the
 * key hints as keycaps. The terminal's own `omp` logo image is omp's mark, not
 * ours.
 */

import { nativeImageNode } from "@oh-my-pi/pi-tui/native/blobs";
import { col, kbd, keyed, node, row, span, text } from "@oh-my-pi/pi-tui/native/describe";
import type { NativeNode } from "@oh-my-pi/pi-tui/native/node";
import { isNativeRendering } from "@oh-my-pi/pi-tui/native/state";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth } from "@oh-my-pi/pi-tui/utils";
import { getTheme, type Theme } from "../theme/theme.ts";

/** The banner's key hints as keycaps; `/help` is typed, not a key. */
const NATIVE_HINTS: readonly { keys?: string; label: string }[] = [
	{ label: "/help" },
	{ keys: "ctrl+p", label: "commands" },
	{ keys: "ctrl+x", label: "sessions" },
	{ keys: "ctrl+o", label: "model" },
	{ keys: "ctrl+c", label: "abort/quit" },
];

/**
 * One character per square pixel; a terminal cell stacks two rows.
 * `#` fruit, `h` gloss, `L` leaf, `.` empty. Even row count, equal widths.
 */
const LEMON_ART: readonly string[] = [
	"..................LLLL..",
	"...............LLLLLL...",
	".........######LLL......",
	"......############......",
	".....##############.....",
	"....####hhhh########....",
	"...###hh#############...",
	"########################",
	"########################",
	"...##################...",
	"....################....",
	".....##############.....",
	"......############......",
	".........######.........",
];

const LOGO_WIDTH = LEMON_ART[0]!.length;
const LOGO_ROWS = LEMON_ART.length / 2;
/** Leaf columns, stem to tip, for its gradient. */
const LEAF_START = Math.min(...LEMON_ART.map((line) => line.indexOf("L")).filter((x) => x >= 0));
const LEAF_END = Math.max(...LEMON_ART.map((line) => line.lastIndexOf("L")));

/** `omp`'s half-block lettering: `l` ascends one row above the x-height. */
const WORDMARK: readonly string[] = ["█", "█ ▄██▄ █▀▄▀▄ ▄▀▀▄ █▀▀▄", "█ ▀▄▄▄ █ █ █ ▀▄▄▀ █  █"];

const GAP = "   ";
/** Below this the hints would truncate to nothing useful beside the logo. */
const MIN_LOGO_LAYOUT_WIDTH = 1 + LOGO_WIDTH + GAP.length + 24;

interface LogoColors {
	/** Fruit gradient, top-left highlight to bottom-right shadow. */
	fruit: readonly string[];
	/** Leaf gradient, stem to tip. */
	leaf: readonly string[];
	gloss: string;
}

const DARK_COLORS: LogoColors = {
	fruit: ["#fff27a", "#ffcf1a", "#ff9f1c"],
	leaf: ["#4caf50", "#c8f07a"],
	gloss: "#fffdeb",
};

/** Deeper stops: the dark palette's pale highlight vanishes on white. */
const LIGHT_COLORS: LogoColors = {
	fruit: ["#f2c200", "#e0a100", "#c27400"],
	leaf: ["#1a7f37", "#5cb85c"],
	gloss: "#fff8d6",
};

/** Intro: one highlight band crossing the mark's diagonal, easing out. */
const INTRO_MS = 1400;
/** Repaint cadence during the intro (~30fps). */
const INTRO_TICK_MS = 33;
/** Half-width of the highlight band, in diagonal units (0 top-left, 1 bottom-right). */
const SHINE_HALF_WIDTH = 0.2;
/** Peak blend toward white at the band's centre. */
const SHINE_STRENGTH = 0.85;

/** Linear interpolation across evenly spaced hex stops, `t` in [0, 1]. */
function mix(stops: readonly string[], t: number): string {
	const segment = Math.min(1, Math.max(0, t)) * (stops.length - 1);
	const index = Math.min(stops.length - 2, Math.floor(segment));
	const f = segment - index;
	const a = Number.parseInt(stops[index]!.slice(1), 16);
	const b = Number.parseInt(stops[index + 1]!.slice(1), 16);
	let hex = "#";
	for (const shift of [16, 8, 0]) {
		const from = (a >> shift) & 0xff;
		const to = (b >> shift) & 0xff;
		hex += Math.round(from + (to - from) * f)
			.toString(16)
			.padStart(2, "0");
	}
	return hex;
}

/**
 * Colour per pixel (undefined where empty). Gradients and the shine run per
 * cell row, so a cell's two fruit halves always match and only gloss or leaf
 * edges need a background colour.
 */
function logoPixels(theme: Theme, shinePos?: number): (string | undefined)[][] {
	const colors = theme.appearance === "light" ? LIGHT_COLORS : DARK_COLORS;
	const leafSpan = Math.max(1, LEAF_END - LEAF_START);
	return LEMON_ART.map((line, y) => {
		const cellRow = Math.floor(y / 2);
		return [...line].map((kind, x) => {
			const diagonal = (x / (LOGO_WIDTH - 1) + cellRow / (LOGO_ROWS - 1)) / 2;
			let color: string;
			if (kind === "#") color = mix(colors.fruit, diagonal);
			else if (kind === "h") color = colors.gloss;
			else if (kind === "L") color = mix(colors.leaf, (x - LEAF_START) / leafSpan);
			else return undefined;
			if (shinePos === undefined) return color;
			const intensity = Math.max(0, 1 - Math.abs(diagonal - shinePos) / SHINE_HALF_WIDTH);
			return intensity > 0 ? mix([color, "#ffffff"], intensity * SHINE_STRENGTH) : color;
		});
	});
}

/** The logo as ANSI rows for cell terminals. */
function paintLogo(theme: Theme, shinePos?: number): string[] {
	const pixels = logoPixels(theme, shinePos);
	const rows: string[] = [];
	for (let y = 0; y < pixels.length; y += 2) {
		let line = "";
		for (let x = 0; x < LOGO_WIDTH; x++) {
			const top = pixels[y]![x];
			const bottom = pixels[y + 1]![x];
			if (top === undefined && bottom === undefined) line += " ";
			else if (bottom === undefined) line += theme.hex(top!, "▀");
			else if (top === undefined) line += theme.hex(bottom, "▄");
			else if (top === bottom || theme.colorLevel === 0) line += theme.hex(top, "█");
			else line += theme.hexBg(bottom, theme.hex(top, "▀"));
		}
		rows.push(line);
	}
	return rows;
}

/** SVG units per pixel; a cell is two pixels tall. */
const SVG_PIXEL = 8;

/**
 * The same pixels as crisp SVG squares for TSP: Tern badges a painted `rows`
 * block as a fallback, and an `ansi` block's line gaps split the half-blocks.
 */
function logoSvg(theme: Theme): string {
	const rects: string[] = [];
	logoPixels(theme).forEach((line, y) => {
		line.forEach((color, x) => {
			if (color === undefined) return;
			// One unit of overlap: scaled abutting squares otherwise show hairline seams.
			rects.push(
				`<rect x="${x * SVG_PIXEL}" y="${y * SVG_PIXEL}" width="${SVG_PIXEL + 1}" height="${SVG_PIXEL + 1}" fill="${color}"/>`,
			);
		});
	});
	const w = LOGO_WIDTH * SVG_PIXEL;
	const h = LEMON_ART.length * SVG_PIXEL;
	return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}" shape-rendering="crispEdges">${rects.join("")}</svg>`;
}

export class Banner implements Component {
	readonly #version: string;
	#width = -1;
	#rows: readonly string[] | undefined;
	#native: { key: string; node: NativeNode } | undefined;
	#introStart: number | undefined;
	#introTimer: NodeJS.Timeout | undefined;

	constructor(version: string) {
		this.#version = version;
	}

	/**
	 * Sweep the highlight across the logo once, repainting through
	 * `requestRender`. A no-op where the logo is not drawn as cells.
	 */
	playIntro(requestRender: () => void): void {
		this.stopIntro();
		if (isNativeRendering() || getTheme().getSymbolPreset() === "ascii") return;
		this.#introStart = performance.now();
		this.#introTimer = setInterval(() => {
			const elapsed = performance.now() - (this.#introStart ?? 0);
			// A TSP surface that opened mid-intro shows the static card instead.
			if (elapsed >= INTRO_MS || isNativeRendering()) this.stopIntro();
			// The settled frame must still paint so the banner can retire.
			requestRender();
		}, INTRO_TICK_MS);
		requestRender();
	}

	/** Settle on the resting frame immediately. Safe when idle. */
	stopIntro(): void {
		if (this.#introTimer === undefined) return;
		clearInterval(this.#introTimer);
		this.#introTimer = undefined;
		this.#introStart = undefined;
		this.#rows = undefined;
	}

	/** While the intro plays the rows still change; scrollback must not freeze one. */
	isTranscriptBlockFinalized(): boolean {
		return this.#introTimer === undefined;
	}

	render(width: number): readonly string[] {
		const shinePos = this.#shinePos();
		if (shinePos === undefined && this.#rows !== undefined && this.#width === width) {
			return this.#rows;
		}
		const theme = getTheme();
		const version = theme.fg("bannerSubtitle", `tui ${this.#version}`);
		const hints = ["/help · Ctrl+P commands · Ctrl+X sessions", "Ctrl+O model · Ctrl+C abort/quit"];
		let rows: string[];
		if (theme.getSymbolPreset() === "ascii" || width < MIN_LOGO_LAYOUT_WIDTH) {
			const title = theme.bold(theme.fg("bannerTitle", "lemon"));
			rows = [` ${title} ${version}  ${theme.fg("dim", hints.join(" · "))}`];
		} else {
			const side = [
				"",
				...WORDMARK.map((line) => theme.bold(theme.fg("bannerTitle", line))),
				version,
				theme.fg("dim", hints[0]!),
				theme.fg("dim", hints[1]!),
			];
			rows = paintLogo(theme, shinePos).map((logo, y) =>
				side[y] ? ` ${logo}${GAP}${side[y]}` : ` ${logo}`,
			);
		}
		rows = rows.map((row) => truncateToWidth(row, Math.max(0, width), ""));
		// Intro frames are one-offs; only the resting frame is worth caching.
		if (shinePos === undefined) {
			this.#rows = rows;
			this.#width = width;
		}
		return rows;
	}

	/** The highlight band's centre for the current intro frame, if one is playing. */
	#shinePos(): number | undefined {
		if (this.#introStart === undefined) return undefined;
		const progress = Math.min(1, (performance.now() - this.#introStart) / INTRO_MS);
		const eased = 1 - (1 - progress) ** 3;
		// Start and end fully off the mark so the first and last frames match rest.
		return -SHINE_HALF_WIDTH + eased * (1 + 2 * SHINE_HALF_WIDTH);
	}

	/**
	 * The welcome card: lockup (painted lemon, wordmark, version) and the key
	 * hints. Rebuilt only when the logo's palette or glyph preset changes.
	 */
	describe(): NativeNode {
		const theme = getTheme();
		const ascii = theme.getSymbolPreset() === "ascii";
		const key = `${theme.appearance}\0${ascii}`;
		if (this.#native?.key === key) return this.#native.node;
		const mark = keyed(
			col(
				[
					keyed(
						text([span("lemon", "strong")], { wrap: "none", role: "omp.welcome.wordmark" }),
						"wordmark",
					),
					keyed(
						text([span(`tui ${this.#version}`, "dim mono")], {
							wrap: "none",
							role: "omp.welcome.version",
						}),
						"version",
					),
				],
				{ role: "omp.welcome.mark" },
			),
			"mark",
		);
		const lockup = ascii
			? [mark]
			: [
					nativeImageNode(
						new TextEncoder().encode(logoSvg(theme)),
						"image/svg+xml",
						{
							alt: "lemon",
							w: LOGO_WIDTH * SVG_PIXEL,
							h: LEMON_ART.length * SVG_PIXEL,
							max: { w: `${LOGO_WIDTH}ch` },
						},
						"logo",
					),
					mark,
				];
		const hints = NATIVE_HINTS.map((hint) =>
			row(
				hint.keys
					? [kbd(hint.keys), text([span(hint.label, "muted")])]
					: [text([span(hint.label, "mono")])],
				{ gap: "xs", align: "center" },
			),
		);
		const described = node("card", { role: "omp.welcome" }, [
			keyed(row(lockup, { align: "center", gap: "md" }), "lockup"),
			keyed(row(hints, { gap: "md", wrap: true, align: "center" }), "hints"),
		]);
		this.#native = { key, node: described };
		return described;
	}

	invalidate(): void {
		this.#rows = undefined;
		this.#width = -1;
		this.#native = undefined;
	}
}
