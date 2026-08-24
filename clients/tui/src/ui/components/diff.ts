/**
 * Colourised diff rendering, adapted from oh-my-pi
 * (`packages/coding-agent/src/modes/components/diff.ts`).
 *
 * Local changes: omp's global `theme` singleton becomes our {@link getTheme},
 * `highlightCode`/`getLanguageFromPath` become {@link highlightWithTheme} plus a
 * small extension table, and `formatCodeFrameLine` is inlined (it is four lines
 * and lived in omp's tool layer).
 *
 * What is kept verbatim, because it is load-bearing:
 *
 *   - **the constant three-digit gutter.** A width derived from the current max
 *     line number widens at the 100-line crossing and re-pads every already
 *     rendered row, which breaks the transcript's append-only commit detection
 *     and forces a full recommit into native scrollback. Streaming rows must be
 *     byte-identical to the final result's rows.
 *   - **word-level intra-line diffing** for a 1-for-1 replacement, with leading
 *     whitespace excluded from the inverse run so indentation is not highlighted.
 *   - **dim indentation glyphs** (`·` per space, ` → ` per tab), so whitespace
 *     changes are visible at all.
 */

import { diffWords } from "@oh-my-pi/pi-natives";
import { replaceTabs } from "@oh-my-pi/pi-tui/utils";
import { getTheme, type Theme } from "../theme/theme.ts";
import { highlightWithTheme } from "../theme/tui-adapters.ts";

/** SGR dim on / normal intensity — additive, so it preserves fg/bg colours. */
const DIM = "\x1b[2m";
const DIM_OFF = "\x1b[22m";

const TAB_WIDTH = 4;

type DiffMarker = "+" | "-" | " ";

interface ParsedDiffLine {
	prefix: DiffMarker;
	lineNum: string;
	content: string;
}

/**
 * Visualise leading whitespace with dim glyphs: tabs become ` → `, spaces `·`.
 * Only the indentation is touched; tabs inside the content become spaces.
 */
function visualizeIndent(text: string, colored: boolean): string {
	const match = text.match(/^([ \t]+)/);
	if (!match) return replaceTabs(text);
	const indent = match[1] ?? "";
	const rest = text.slice(indent.length);
	const leftPadding = Math.floor(TAB_WIDTH / 2);
	const rightPadding = Math.max(0, TAB_WIDTH - leftPadding - 1);
	const tab = `${" ".repeat(leftPadding)}→${" ".repeat(rightPadding)}`;
	// Without colour the SGR pair is pure noise in the output stream (the gallery
	// and every ANSI-stripped test read this), so the glyphs go out bare.
	const on = colored ? DIM : "";
	const off = colored ? DIM_OFF : "";
	let visible = "";
	for (const char of indent) {
		visible += char === "\t" ? `${on}${tab}${off}` : `${on}·${off}`;
	}
	return `${visible}${replaceTabs(rest)}`;
}

/**
 * Parse a diff row. Canonical form is `+123|content`; the legacy `+123 content`
 * and the bare `+content` (a raw unified-diff hunk body) are also accepted.
 */
function parseDiffLine(line: string): ParsedDiffLine | null {
	const canonical = line.match(/^([+\-\s])(\s*\d+)\|(.*)$/);
	if (canonical) {
		return {
			prefix: canonical[1] as DiffMarker,
			lineNum: canonical[2] ?? "",
			content: canonical[3] ?? "",
		};
	}
	const legacy = line.match(/^([+\-\s])(?:(\s*\d+)\s)?(.*)$/);
	if (!legacy) return null;
	return {
		prefix: legacy[1] as DiffMarker,
		lineNum: legacy[2] ?? "",
		content: legacy[3] ?? "",
	};
}

/** `-  12│content`, with a fixed-width gutter (see the file header). */
function formatCodeFrameLine(
	marker: DiffMarker,
	lineNumber: string,
	content: string,
	lineNumberWidth: number,
	theme: Theme,
): string {
	const markerText = marker.trim();
	const numberText = lineNumber.trim();
	const gutter = markerText && numberText ? `${markerText}${numberText}` : numberText || markerText;
	return `${gutter.padStart(lineNumberWidth + 1, " ")}${theme.quoteBorder}${content}`;
}

/**
 * Word-level diff of a 1-for-1 replacement, with the changed runs inversed.
 * Leading whitespace is excluded from the first inverse run so re-indentation
 * does not paint the whole line.
 */
function renderIntraLineDiff(
	oldContent: string,
	newContent: string,
	theme: Theme,
): { removedLine: string; addedLine: string } {
	let removedLine = "";
	let addedLine = "";
	let isFirstRemoved = true;
	let isFirstAdded = true;

	for (const part of diffWords(oldContent, newContent)) {
		if (part.removed || part.added) {
			const first = part.removed ? isFirstRemoved : isFirstAdded;
			let value = part.value;
			let leading = "";
			if (first) {
				leading = value.match(/^(\s*)/)?.[1] ?? "";
				value = value.slice(leading.length);
				if (part.removed) isFirstRemoved = false;
				else isFirstAdded = false;
			}
			const rendered = leading + (value ? theme.inverse(value) : "");
			if (part.removed) removedLine += rendered;
			else addedLine += rendered;
		} else {
			removedLine += part.value;
			addedLine += part.value;
		}
	}

	return { removedLine, addedLine };
}

/** Extensions the syntax highlighter is worth calling for. */
const LANGUAGE_BY_EXTENSION: Record<string, string> = {
	c: "c",
	cc: "cpp",
	cpp: "cpp",
	cs: "csharp",
	css: "css",
	ex: "elixir",
	exs: "elixir",
	go: "go",
	h: "c",
	hpp: "cpp",
	html: "html",
	java: "java",
	js: "javascript",
	json: "json",
	jsx: "jsx",
	kt: "kotlin",
	lua: "lua",
	md: "markdown",
	mjs: "javascript",
	php: "php",
	py: "python",
	rb: "ruby",
	rs: "rust",
	sh: "bash",
	sql: "sql",
	swift: "swift",
	toml: "toml",
	ts: "typescript",
	tsx: "tsx",
	yaml: "yaml",
	yml: "yaml",
	zsh: "bash",
};

export function languageFromPath(path: string | undefined): string | undefined {
	if (!path) return undefined;
	const extension = path.slice(path.lastIndexOf(".") + 1).toLowerCase();
	return LANGUAGE_BY_EXTENSION[extension];
}

/**
 * Batch-highlight runs of consecutive context lines so they tokenize with full
 * multi-line context. Returns a map from index in `parsed` to highlighted
 * content; absent entries fall back to plain rendering.
 */
function highlightContextLines(
	parsed: readonly (ParsedDiffLine | null)[],
	path: string | undefined,
	theme: Theme,
): Map<number, string> {
	const map = new Map<number, string>();
	const lang = languageFromPath(path);
	if (!lang) return map;

	let indices: number[] = [];
	let contents: string[] = [];
	const flush = () => {
		if (contents.length === 0) return;
		const highlighted = highlightWithTheme(contents.join("\n"), lang, theme);
		if (highlighted !== null) {
			const lines = highlighted.split("\n");
			for (let k = 0; k < indices.length; k++) {
				const index = indices[k];
				if (index !== undefined) map.set(index, lines[k] ?? contents[k] ?? "");
			}
		}
		indices = [];
		contents = [];
	};

	for (let i = 0; i < parsed.length; i++) {
		const line = parsed[i];
		// Collapse markers are emitted as context but are not code: highlighting
		// them produces nonsense and stitches unrelated regions together.
		const isCollapseMarker =
			line?.prefix === " " && (line.content === "..." || line.content === "…");
		if (line && line.prefix === " " && !isCollapseMarker) {
			indices.push(i);
			contents.push(line.content);
		} else {
			flush();
		}
	}
	flush();
	return map;
}

export interface RenderDiffOptions {
	/** File the diff applies to; drives syntax highlighting of context lines. */
	path?: string;
	/** Cap on emitted rows. The overflow is reported on a trailing dim line. */
	maxLines?: number;
}

/**
 * Render a diff to styled lines: context dim (syntax-highlighted when the path
 * gives away a language), removals red, additions green, changed tokens inversed.
 */
export function renderDiff(diffText: string, options: RenderDiffOptions = {}): string[] {
	const theme = getTheme();
	const colored = theme.colorLevel > 0;
	const lines = diffText.split(/\r?\n/);
	const parsed = lines.map(parseDiffLine);
	// Constant gutter through 999 lines: see the file header for why this must
	// not be derived from the current maximum.
	const lineNumberWidth = parsed.reduce(
		(width, line) => Math.max(width, (line?.lineNum ?? "").trim().length),
		3,
	);
	const contextHighlights = highlightContextLines(parsed, options.path, theme);
	const result: string[] = [];
	// Blank a repeated gutter number: a single-line replacement renders `-N` then
	// `+N`, and an insertion followed by context repeats the old line number.
	let previousLineNum = "";

	const formatLine = (prefix: DiffMarker, lineNum: string, content: string): string => {
		if (lineNum.trim().length === 0) {
			previousLineNum = "";
			return `${prefix}${content}`;
		}
		const trimmed = lineNum.trim();
		const display = trimmed === previousLineNum ? "" : trimmed;
		previousLineNum = trimmed;
		return formatCodeFrameLine(prefix, display, content, lineNumberWidth, theme);
	};

	let i = 0;
	while (i < lines.length) {
		const line = lines[i] ?? "";
		const current = parsed[i] ?? null;

		if (!current) {
			previousLineNum = "";
			const trimmed = line.trim();
			const isGap = trimmed.length === 0 || trimmed === "..." || trimmed === "…";
			result.push(theme.fg("dim", isGap ? "…" : replaceTabs(line)));
			i++;
			continue;
		}

		if (current.prefix === "-") {
			const removed: ParsedDiffLine[] = [];
			while (i < lines.length && parsed[i]?.prefix === "-") {
				removed.push(parsed[i] as ParsedDiffLine);
				i++;
			}
			const added: ParsedDiffLine[] = [];
			while (i < lines.length && parsed[i]?.prefix === "+") {
				added.push(parsed[i] as ParsedDiffLine);
				i++;
			}

			if (removed.length === 1 && added.length === 1) {
				const from = removed[0] as ParsedDiffLine;
				const to = added[0] as ParsedDiffLine;
				const intra = renderIntraLineDiff(
					replaceTabs(from.content),
					replaceTabs(to.content),
					theme,
				);
				result.push(
					theme.fg(
						"toolDiffRemoved",
						formatLine("-", from.lineNum, visualizeIndent(intra.removedLine, colored)),
					),
				);
				result.push(
					theme.fg(
						"toolDiffAdded",
						formatLine("+", to.lineNum, visualizeIndent(intra.addedLine, colored)),
					),
				);
			} else {
				for (const row of removed) {
					result.push(
						theme.fg(
							"toolDiffRemoved",
							formatLine("-", row.lineNum, visualizeIndent(row.content, colored)),
						),
					);
				}
				for (const row of added) {
					result.push(
						theme.fg(
							"toolDiffAdded",
							formatLine("+", row.lineNum, visualizeIndent(row.content, colored)),
						),
					);
				}
			}
		} else if (current.prefix === "+") {
			result.push(
				theme.fg(
					"toolDiffAdded",
					formatLine("+", current.lineNum, visualizeIndent(current.content, colored)),
				),
			);
			i++;
		} else {
			const highlighted = contextHighlights.get(i);
			const content =
				highlighted !== undefined
					? replaceTabs(highlighted)
					: visualizeIndent(current.content, colored);
			result.push(theme.fg("dim", formatLine(" ", current.lineNum, content)));
			i++;
		}
	}

	const max = options.maxLines;
	if (max !== undefined && result.length > max) {
		const hidden = result.length - max;
		return [...result.slice(0, max), theme.fg("dim", `… ${hidden} more diff lines`)];
	}
	return result;
}
