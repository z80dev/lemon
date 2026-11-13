/**
 * Link detection and keyboard hint tags for Lemon's link browser.
 *
 * omp's `render/link-hints` finds links through `extensionLinkLabels`, which only matches omp's
 * own OSC 8 markers of schemes registered process-wide with `setExtensionLinks`. Registering
 * schemes would change how every other markdown component draws while a browser is open (and
 * what a streaming reply commits to scrollback), so this module detects Lemon's links itself,
 * straight from the rendered rows, and keeps no global state:
 *
 *  - OSC 8 hyperlinks (markdown links, file locations, URLs in code) of an allowed scheme;
 *  - bare `http(s)` URLs in visible text outside any hyperlink.
 *
 * {@link LinkHints} is omp's tag assignment and painting (same alphabet, same prefix-free tag
 * rules, same drawing) over those targets. Only the detection differs.
 */

import { compositeLineAt } from "@oh-my-pi/pi-tui/render/composite";
import { theme } from "@oh-my-pi/pi-tui/theme/theme";
import { sliceByColumn, visibleWidth } from "@oh-my-pi/pi-tui/utils";

/** Schemes the browser tags; `terminal/open-link.ts` opens exactly these. */
export const LINK_SCHEMES = ["http", "https", "file"] as const;

/** One OSC 8 sequence; group 1 params, group 2 URI (empty for a close). */
// biome-ignore lint/suspicious/noControlCharactersInRegex: OSC 8 hyperlinks are ESC/BEL delimited.
const OSC8_PATTERN = /\x1b\]8;([^;\x07\x1b]*);([^\x07\x1b]*)(?:\x07|\x1b\\)/g;
/** Any escape sequence at a position (CSI or OSC), for walking a row's visible text. */
// biome-ignore lint/suspicious/noControlCharactersInRegex: Walk CSI and OSC escape sequences in rendered rows.
const ESCAPE_PATTERN = /\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\))/y;
// biome-ignore lint/suspicious/noControlCharactersInRegex: An OSC 8 close is ESC/BEL delimited.
const OSC8_CLOSE_PATTERN = /^\x1b\]8;[^;\x07\x1b]*;(?:\x07|\x1b\\)$/;

// biome-ignore lint/suspicious/noControlCharactersInRegex: A URL in rendered text ends at any control byte.
const URL_PATTERN = /(?<![A-Za-z0-9+.-])https?:\/\/[^\s\x00-\x1f\x7f<>"'`]+/g;
const URL_TRAILING_PATTERN = /[.,;:!?]+$/;
const URL_OPENERS: Partial<Record<string, string>> = { ")": "(", "]": "[", "}": "{" };

/** Hint tag letters, home row first: what a tag falls back to after its label's own letters. */
const LINK_HINT_ALPHABET = "asdfghjklqwertyuiopzxcvbnm";
/** Most tags one session holds: every two-letter tag. Links past it stay untagged. */
const MAX_TAGS = LINK_HINT_ALPHABET.length * LINK_HINT_ALPHABET.length;

function linkScheme(uri: string): string | undefined {
	const colon = uri.indexOf(":");
	if (colon <= 0) return undefined;
	const scheme = uri.slice(0, colon).toLowerCase();
	return (LINK_SCHEMES as readonly string[]).includes(scheme) ? scheme : undefined;
}

function endsWithUnbalancedCloser(url: string): boolean {
	const closer = url.at(-1) ?? "";
	const opener = URL_OPENERS[closer];
	return opener !== undefined && url.split(closer).length > url.split(opener).length;
}

/** A link drawn on one rendered row. */
export interface LinkLabel {
	readonly url: string;
	/**
	 * Tells one link from an adjacent one of the same URL. A hyperlink wrapped across rows repeats
	 * its params and URI on every row, so its parts share an id.
	 */
	readonly id: string;
	/** First 0-based cell the label covers. */
	readonly start: number;
	/** Cell just past the label. */
	readonly end: number;
	/** Whether only blank cells follow the label on its row, so a wrapped label may go on below. */
	readonly endsRow: boolean;
}

interface RawLabel {
	url: string;
	id: string;
	start: number;
	end: number;
	/** Code-unit index in the row where the label's text ends. */
	endOffset: number;
}

/** The OSC 8 hyperlinks of an allowed scheme on `line`, left to right. */
function hyperlinkLabels(line: string): RawLabel[] {
	const labels: RawLabel[] = [];
	let x = 0;
	let cursor = 0;
	let open: { url: string; id: string; start: number } | undefined;
	for (const match of line.matchAll(OSC8_PATTERN)) {
		x += visibleWidth(line.slice(cursor, match.index));
		if (open && x > open.start) labels.push({ ...open, end: x, endOffset: match.index });
		open = undefined;
		cursor = match.index + match[0].length;
		const params = match[1]!;
		const uri = match[2]!;
		if (uri && linkScheme(uri)) open = { url: uri, id: `${params}\0${uri}`, start: x };
	}
	x += visibleWidth(line.slice(cursor));
	if (open && x > open.start) labels.push({ ...open, end: x, endOffset: line.length });
	return labels;
}

/**
 * The bare `http(s)` URLs in `line`'s visible text outside any hyperlink. Trailing punctuation and
 * unbalanced closers are not part of a URL. With `width`, a URL running to the row's last cell is
 * left out: it may be the first part of one the renderer wrapped, and opening half a URL is worse
 * than not offering it.
 */
function plainUrlLabels(line: string, width: number | undefined): RawLabel[] {
	if (!line.includes("://")) return [];
	let visible = "";
	const offsets: number[] = [];
	let inLink = false;
	for (let i = 0; i < line.length; ) {
		if (line.charCodeAt(i) === 0x1b) {
			ESCAPE_PATTERN.lastIndex = i;
			const match = ESCAPE_PATTERN.exec(line);
			if (match) {
				if (match[0].startsWith("\x1b]8;")) {
					inLink = !OSC8_CLOSE_PATTERN.test(match[0]);
					// A hyperlink boundary ends any URL running into it.
					visible += "\0";
					offsets.push(i);
				}
				i += match[0].length;
				continue;
			}
		}
		// Text inside a hyperlink is already a link: hide it from the URL search.
		visible += inLink ? "\0" : line[i];
		offsets.push(i);
		i++;
	}
	const labels: RawLabel[] = [];
	for (const match of visible.matchAll(URL_PATTERN)) {
		let url = match[0].replace(URL_TRAILING_PATTERN, "");
		while (endsWithUnbalancedCloser(url)) {
			url = url.slice(0, -1).replace(URL_TRAILING_PATTERN, "");
		}
		if (!/:\/\/./.test(url)) continue;
		const startOffset = offsets[match.index]!;
		const endOffset = offsets[match.index + url.length - 1]! + 1;
		const start = visibleWidth(line.slice(0, startOffset));
		const end = visibleWidth(line.slice(0, endOffset));
		if (width !== undefined && end >= width - 1) continue;
		labels.push({ url, id: `plain\0${url}\0${start}`, start, end, endOffset });
	}
	return labels;
}

/** The links drawn on a rendered row, left to right. */
export function rowLinkLabels(line: string, width?: number): LinkLabel[] {
	if (!line.includes("\x1b]8;") && !line.includes("://")) return [];
	const raw = [...hyperlinkLabels(line), ...plainUrlLabels(line, width)].sort(
		(a, b) => a.start - b.start,
	);
	return raw.map(({ endOffset, ...label }) => ({
		...label,
		endsRow: Bun.stripANSI(line.slice(endOffset)).trim() === "",
	}));
}

/** A link drawn on a shown row: what a hint tag lands on. */
export interface LinkTarget {
	readonly url: string;
	/** Shown row the label is drawn on (its first row, for a label wrapped across rows). */
	readonly row: number;
	/** First cell of the label's part on that row. */
	readonly start: number;
	readonly id: string;
	/** The label's text, across every shown row it wraps to; its tag prefers these letters. */
	readonly text: string;
	/** Where each shown row's part of the label starts, top to bottom; the first is `row`/`start`. */
	readonly parts: readonly { readonly row: number; readonly start: number }[];
}

/**
 * The links drawn on `rows`, top to bottom, a wrapped link once at its first row: a row's first
 * label continues the previous row's last label when that has the same id and ends its row.
 */
export function linkTargets(rows: readonly string[], width?: number): LinkTarget[] {
	const targets: {
		url: string;
		row: number;
		start: number;
		id: string;
		text: string;
		parts: { row: number; start: number }[];
	}[] = [];
	let previous: LinkLabel | undefined;
	for (let row = 0; row < rows.length; row++) {
		const line = rows[row]!;
		const labels = rowLinkLabels(line, width);
		for (const [index, label] of labels.entries()) {
			const text = Bun.stripANSI(sliceByColumn(line, label.start, label.end - label.start));
			const continued = targets.at(-1);
			if (index === 0 && previous?.endsRow && previous.id === label.id && continued) {
				continued.text += text;
				continued.parts.push({ row, start: label.start });
				continue;
			}
			// Markdown draws `[text](url)` as the text and a parenthesized copy of the URL, both
			// linked: one link to pick, not two.
			const duplicate = targets.at(-1);
			if (
				duplicate?.row === row &&
				duplicate.url === label.url &&
				text.startsWith("(") &&
				text.endsWith(")")
			) {
				continue;
			}
			targets.push({
				url: label.url,
				row,
				start: label.start,
				id: label.id,
				text,
				parts: [{ row, start: label.start }],
			});
		}
		previous = labels.at(-1);
	}
	return targets;
}

/** The letters a label's tag tries, in order: the label's own (its first one first), then the alphabet. */
function tagLetters(text: string): string[] {
	const letters = new Set<string>();
	for (const char of text.toLowerCase()) if (char >= "a" && char <= "z") letters.add(char);
	for (const char of LINK_HINT_ALPHABET) letters.add(char);
	return [...letters];
}

/**
 * The first tag for a label reading `text` that keeps `used` prefix-free: a single letter that is
 * no tag and starts none, else two letters whose first is no single-letter tag; `undefined` when
 * none is left. With `twoLetters`, only two-letter tags are tried.
 */
function pickTag(text: string, used: ReadonlySet<string>, twoLetters = false): string | undefined {
	const letters = tagLetters(text);
	if (!twoLetters) {
		const firsts = new Set<string>();
		for (const tag of used) firsts.add(tag[0]!);
		const single = letters.find((letter) => !firsts.has(letter));
		if (single !== undefined) return single;
	}
	for (const first of letters) {
		if (used.has(first)) continue;
		for (const second of letters) if (!used.has(`${first}${second}`)) return `${first}${second}`;
	}
	return undefined;
}

/** What tells one row part of a link apart across repaints. */
function partKey(row: number, start: number, link: LinkTarget): string {
	return `${row}\0${start}\0${link.id}\0${link.url}`;
}

interface LinkHint {
	readonly tag: string;
	readonly link: LinkTarget;
	/** The row each shown row part is on in the whole content (shown row plus origin). */
	readonly rows: readonly number[];
}

/**
 * The tags of one hint session and the letters typed so far. A tag is drawn over the first cell of
 * its label, so it prefers the letters it covers: the label's first letter, then its others, then
 * the home row. Tags never prefix one another.
 */
export class LinkHints {
	#hints: LinkHint[] = [];
	#typed = "";

	/**
	 * Tag what `rows` draw now, keeping each link's tag while it stays in view: tags of links no
	 * longer drawn are dropped and only newly drawn links get one, top to bottom. A link is the same
	 * across repaints when one of its row parts is (row plus `origin`, first cell, id and URL).
	 *
	 * The one time existing tags change: a new link finds no tag that keeps the set prefix-free.
	 * Then every link is tagged afresh with two letters, and the letters typed are forgotten.
	 */
	update(rows: readonly string[], origin = 0, width?: number): void {
		const kept = new Map<string, string>();
		for (const { link, rows: partRows, tag } of this.#hints) {
			for (const [index, part] of link.parts.slice(0, partRows.length).entries()) {
				kept.set(partKey(partRows[index]!, part.start, link), tag);
			}
		}
		const targets = linkTargets(rows, width).map((link) => {
			const partRows = link.parts.map((part) => part.row + origin);
			return {
				link,
				rows: partRows,
				keys: link.parts.map((part, index) => partKey(partRows[index]!, part.start, link)),
			};
		});
		const used = new Set<string>();
		const tags = targets.map(({ keys }) => {
			const tag = keys
				.map((key) => kept.get(key))
				.find((found) => found !== undefined && !used.has(found));
			if (tag !== undefined) used.add(tag);
			return tag;
		});
		let hints: LinkHint[] = [];
		let exhausted = false;
		for (const [index, { link, rows: partRows }] of targets.entries()) {
			let tag = tags[index];
			if (tag === undefined) {
				// Past the cap a link stays untagged.
				if (used.size >= MAX_TAGS) continue;
				tag = pickTag(link.text, used);
				if (tag === undefined) {
					exhausted = true;
					break;
				}
				used.add(tag);
			}
			hints.push({ tag, link, rows: partRows });
		}
		if (exhausted) {
			hints = [];
			used.clear();
			for (const { link, rows: partRows } of targets.slice(0, MAX_TAGS)) {
				// Two letters each leave 676 prefix-free tags, so one is always left.
				const tag = pickTag(link.text, used, true)!;
				used.add(tag);
				hints.push({ tag, link, rows: partRows });
			}
			this.#typed = "";
		}
		this.#hints = hints;
		if (!hints.some(({ tag }) => tag.startsWith(this.#typed))) this.#typed = "";
	}

	/** Whether some row holds more tag cells than `width`, so its tags could not all be read side by side. */
	crowded(width: number): boolean {
		const cells = new Map<number, number>();
		for (const { tag, link } of this.#hints)
			cells.set(link.row, (cells.get(link.row) ?? 0) + tag.length);
		for (const count of cells.values()) if (count > width) return true;
		return false;
	}

	/**
	 * Type one letter of a tag. Returns the URL whose whole tag is now typed, `true` while the
	 * letters still lead to several tags, and `false` when none starts with them. A pick or a miss
	 * forgets the letters typed.
	 */
	type(letter: string): string | boolean {
		const typed = this.#typed + letter.toLowerCase();
		const matching = this.#hints.filter((hint) => hint.tag.startsWith(typed));
		const picked =
			matching.length === 1 && matching[0]!.tag === typed ? matching[0]!.link : undefined;
		if (matching.length === 0 || picked !== undefined) {
			this.#typed = "";
			return picked === undefined ? false : picked.url;
		}
		this.#typed = typed;
		return true;
	}

	/**
	 * Draw every tag the typed letters still lead to over the start of its label, within the first
	 * `width` cells of each row (cells past it, such as a scrollbar, are kept). Tags on one row never
	 * overlap: one that would land on an earlier tag moves right, and tags that would run past
	 * `width` move left.
	 */
	paint(rows: readonly string[], width: number): string[] {
		const painted = [...rows];
		const byRow = new Map<number, { tag: string; col: number }[]>();
		for (const { tag, link } of this.#hints) {
			if (rows[link.row] === undefined || !tag.startsWith(this.#typed)) continue;
			const row = byRow.get(link.row) ?? [];
			byRow.set(link.row, row);
			row.push({ tag, col: link.start });
		}
		for (const [index, tags] of byRow) {
			tags.sort((a, b) => a.col - b.col);
			let free = 0;
			for (const placed of tags) {
				placed.col = Math.max(placed.col, free);
				free = placed.col + placed.tag.length;
			}
			let limit = width;
			for (let i = tags.length - 1; i >= 0; i--) {
				const placed = tags[i]!;
				placed.col = Math.max(0, Math.min(placed.col, limit - placed.tag.length));
				limit = placed.col;
			}
			let line = painted[index]!;
			const lineWidth = Math.max(width, visibleWidth(line));
			for (const { tag, col } of tags) {
				// Raw SGR like the hover highlight: chalk's inverse/bold drop out when it detects no color.
				const styled = `\x1b[1;7m${theme.fg("accent", tag)}\x1b[22;27m`;
				line = compositeLineAt(line, styled, col, tag.length, lineWidth);
			}
			painted[index] = line;
		}
		return painted;
	}
}
