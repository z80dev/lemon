/**
 * Base utility functions for formatters.
 *
 * These utilities help format tool arguments and results in a consistent,
 * human-readable way across all tool formatters.
 */

import { homedir } from "node:os";
import { relative, sep } from "node:path";
import { sanitizeText } from "@oh-my-pi/pi-utils/sanitize-text";

/**
 * Untrusted text (answers, tool receipts, notices, delegate text) made safe to
 * print: escape sequences, C0/C1 control bytes, DEL and lone surrogates are
 * removed and line endings normalized; tabs and newlines stay.
 */
export function safeText(text: string): string {
	return sanitizeText(text);
}

/** {@link displayText} as one line: every whitespace run becomes one space, bounded. */
export function safeLine(text: string, maxLength = 200): string {
	const line = displayText(text).replace(/\s+/g, " ").trim();
	return line.length > maxLength ? `${line.slice(0, maxLength - 1)}…` : line;
}

/**
 * Invisible characters that can reorder or hide what a reader sees: bidi
 * embeddings, overrides, isolates and marks; zero-width spaces and joiners;
 * word joiners and invisible operators; soft hyphens; BOMs; interlinear
 * annotation; Unicode tag characters (hidden "ASCII smuggling"). A joiner
 * inside an emoji sequence and the tags of a subdivision flag stay, since
 * those render as one visible glyph.
 */
const INVISIBLE_FORMAT =
	/[\u00AD\u061C\u180E\u200B\u200C\u200E\u200F\u202A-\u202E\u2060-\u2064\u2066-\u206F\uFEFF\uFFF9-\uFFFB]|(?<!\p{Extended_Pictographic}\uFE0F?)\u200D|\u200D(?!\p{Extended_Pictographic})|(?<!\u{1F3F4}[\u{E0020}-\u{E007E}]*)[\u{E0000}-\u{E007F}]/gu;

function codePointMarker(char: string): string {
	const code = char.codePointAt(0)!;
	if (code < 0x20) return String.fromCodePoint(0x2400 + code);
	if (code === 0x7f) return "␡";
	return `⟨U+${code.toString(16).toUpperCase().padStart(4, "0")}⟩`;
}

/**
 * Untrusted text for the transcript, status line and pickers: {@link safeText}
 * plus every {@link INVISIBLE_FORMAT} character shown as `⟨U+XXXX⟩`, so bidi or
 * zero-width tricks cannot disguise a filename, command or code. Stored
 * blocks keep the text as received; `/copy` copies that, not this rendering.
 */
export function displayText(text: string): string {
	return safeText(text).replace(INVISIBLE_FORMAT, codePointMarker);
}

/** A character Markdown must not be allowed to produce from an entity. */
const UNSAFE_DECODED = /^[\p{Cc}\p{Cf}\p{Cs}\u2028\u2029]$/u;

/**
 * {@link displayText} for Markdown source. The renderer decodes numeric
 * character references (`&#27;`, `&#x1b`, with or without the semicolon) after
 * any text-level sanitizing, so a reference that would decode to a control,
 * format or surrogate character (or to nothing valid) is replaced by its
 * visible marker before the renderer sees it — in text, link labels, image
 * alt text, inline HTML and code alike.
 */
export function displayMarkdown(text: string): string {
	return displayText(text).replace(
		/&#(?:[xX]([0-9a-fA-F]+)|(\d+));?/g,
		(reference, hex: string | undefined, decimal: string | undefined) => {
			const code = hex !== undefined ? Number.parseInt(hex, 16) : Number.parseInt(decimal!, 10);
			if (!Number.isSafeInteger(code) || code > 0x10ffff) return "⟨invalid⟩";
			const char = String.fromCodePoint(code);
			if (UNSAFE_DECODED.test(char) || char.replace(INVISIBLE_FORMAT, "") === "") {
				return codePointMarker(char);
			}
			return reference;
		},
	);
}

/**
 * {@link displayMarkdown} over every string and object key of a JSON-shaped
 * value, for views that build their own nodes from raw tool details. Plain
 * objects and arrays are copied; anything else passes through. Nesting past
 * {@link DISPLAY_DEPTH} is elided rather than walked, so hostile details cannot
 * exhaust the stack.
 */
export function displayDeep(value: unknown, depth = 0): unknown {
	if (typeof value === "string") return displayMarkdown(value);
	if (value === null || typeof value !== "object") return value;
	if (depth >= DISPLAY_DEPTH) return "…";
	if (Array.isArray(value)) return value.map((entry) => displayDeep(entry, depth + 1));
	if (Object.getPrototypeOf(value) !== Object.prototype) return value;
	const out: Record<string, unknown> = {};
	for (const [key, entry] of Object.entries(value)) {
		out[displayMarkdown(key)] = displayDeep(entry, depth + 1);
	}
	return out;
}

const DISPLAY_DEPTH = 64;

/** True when `text` holds any C0/C1 control or DEL byte (tab and newline included). */
export function hasControlChars(text: string): boolean {
	return /\p{Cc}/u.test(text);
}

/**
 * Untrusted text for an authority surface (the approval panel): instead of
 * dropping control bytes, which would hide that the text was tampered with,
 * each one is shown as a visible marker — `␛` for ESC, `␍` for CR, `␉` for a
 * tab, `␡` for DEL, `⟨U+009B⟩` for a C1 control. Format characters that can
 * reorder or hide text (bidi overrides, zero-width joiners, soft hyphens),
 * lone surrogates and line/paragraph separators are shown the same way.
 * Newlines stay.
 */
export function visibleControls(text: string): string {
	return text.replace(/[\p{Cc}\p{Cf}\p{Cs}\u2028\u2029]/gu, (char: string) =>
		char === "\n" ? char : codePointMarker(char),
	);
}

/**
 * Truncates text to a maximum length, adding "..." if truncated.
 *
 * @param text - The text to truncate
 * @param maxLength - Maximum number of characters (including "...")
 * @returns The truncated text
 */
export function truncateText(text: string, maxLength: number): string {
	if (maxLength < 4) {
		// Not enough room for any content + "..."
		return text.slice(0, maxLength);
	}
	if (text.length <= maxLength) {
		return text;
	}
	return `${text.slice(0, maxLength - 3)}...`;
}

/**
 * Truncates an array of lines to a maximum count.
 *
 * @param lines - The lines to truncate
 * @param maxLines - Maximum number of lines to keep
 * @param showCount - Whether to show "(N more)" indicator (default: true)
 * @returns The truncated lines array
 */
export function truncateLines(lines: string[], maxLines: number, showCount = true): string[] {
	if (lines.length <= maxLines) {
		return lines;
	}
	const kept = lines.slice(0, maxLines);
	if (showCount) {
		const remaining = lines.length - maxLines;
		kept.push(`... (${remaining} more)`);
	}
	return kept;
}

/**
 * Formats a file path for display, making it relative to cwd and using ~ for home.
 *
 * @param path - The absolute path to format
 * @param cwd - Current working directory (optional)
 * @returns The formatted path
 */
export function formatPath(path: string, cwd?: string): string {
	if (!path) {
		return "";
	}

	const home = homedir();

	// Try to make path relative to cwd first
	if (cwd) {
		// Normalize both paths for comparison
		const normalizedPath = path.replace(/\/$/, "");
		const normalizedCwd = cwd.replace(/\/$/, "");

		// Check if path is within cwd
		if (normalizedPath.startsWith(normalizedCwd + sep) || normalizedPath === normalizedCwd) {
			const relativePath = relative(normalizedCwd, normalizedPath);
			// Only use relative path if it's simpler (doesn't go up many directories)
			if (relativePath && !relativePath.startsWith(`..${sep}..${sep}..`)) {
				return relativePath || ".";
			}
		}
	}

	// Replace home directory with ~
	if (home && path.startsWith(home)) {
		return `~${path.slice(home.length)}`;
	}

	return path;
}

/**
 * Formats a duration in milliseconds to a human-readable string.
 *
 * @param ms - Duration in milliseconds
 * @returns Formatted duration string (e.g., "123ms", "4.5s", "2m 30s")
 */
export function formatDuration(ms: number): string {
	if (ms < 0) {
		return "0ms";
	}
	if (ms < 1000) {
		return `${Math.round(ms)}ms`;
	}
	const seconds = ms / 1000;
	if (seconds < 60) {
		// Show one decimal place for seconds < 10, otherwise round
		if (seconds < 10) {
			return `${seconds.toFixed(1)}s`;
		}
		return `${Math.round(seconds)}s`;
	}
	const minutes = Math.floor(seconds / 60);
	const remainingSeconds = Math.round(seconds % 60);
	if (remainingSeconds === 0) {
		return `${minutes}m`;
	}
	return `${minutes}m ${remainingSeconds}s`;
}

/**
 * Formats a byte count to a human-readable string.
 *
 * @param bytes - Number of bytes
 * @returns Formatted size string (e.g., "1.2 KB", "3.4 MB")
 */
export function formatBytes(bytes: number): string {
	if (bytes < 0) {
		return "0 B";
	}
	if (bytes === 0) {
		return "0 B";
	}
	if (bytes < 1024) {
		return `${bytes} B`;
	}
	const kb = bytes / 1024;
	if (kb < 1024) {
		return kb < 10 ? `${kb.toFixed(1)} KB` : `${Math.round(kb)} KB`;
	}
	const mb = kb / 1024;
	if (mb < 1024) {
		return mb < 10 ? `${mb.toFixed(1)} MB` : `${Math.round(mb)} MB`;
	}
	const gb = mb / 1024;
	return gb < 10 ? `${gb.toFixed(1)} GB` : `${Math.round(gb)} GB`;
}

/**
 * Highlights regex pattern matches in text using a provided highlight function.
 *
 * @param text - The text to search in
 * @param pattern - The regex pattern string to highlight
 * @param highlightFn - Function to apply highlighting to matched text
 * @returns The text with matches highlighted
 */
export function highlightPattern(
	text: string,
	pattern: string,
	highlightFn: (s: string) => string,
): string {
	if (!pattern || !text) {
		return text;
	}

	try {
		// Escape special regex characters in the pattern for literal matching
		const escapedPattern = pattern.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
		const regex = new RegExp(`(${escapedPattern})`, "gi");
		return text.replace(regex, (match) => highlightFn(match));
	} catch {
		// If regex construction fails, return original text
		return text;
	}
}

/**
 * Extracts text content from a tool result.
 *
 * Handles various result formats:
 * - Plain strings
 * - Numbers and booleans (converted to string)
 * - Content block arrays (extracts text from text blocks)
 * - Objects with content or text properties
 *
 * @param result - The tool result to extract text from
 * @returns The extracted text content
 */
export function extractText(result: unknown): string {
	if (result === null || result === undefined) {
		return "";
	}

	if (typeof result === "string") {
		return result;
	}

	if (typeof result === "number" || typeof result === "boolean") {
		return String(result);
	}

	if (Array.isArray(result)) {
		return extractTextFromContentBlocks(result);
	}

	if (typeof result === "object") {
		const obj = result as Record<string, unknown>;

		// Try content field first (common in tool results)
		if (obj.content !== undefined) {
			if (typeof obj.content === "string") {
				return obj.content;
			}
			if (Array.isArray(obj.content)) {
				return extractTextFromContentBlocks(obj.content);
			}
		}

		// Try text field
		if (typeof obj.text === "string") {
			return obj.text;
		}

		// Try output field
		if (typeof obj.output === "string") {
			return obj.output;
		}

		// Try message field
		if (typeof obj.message === "string") {
			return obj.message;
		}
	}

	return "";
}

/**
 * Extracts text from an array of content blocks.
 *
 * @param blocks - Array of content blocks
 * @returns Combined text from all text blocks
 */
function extractTextFromContentBlocks(blocks: unknown[]): string {
	const parts: string[] = [];
	let imageCount = 0;

	for (const block of blocks) {
		if (!block || typeof block !== "object") {
			continue;
		}

		const typed = block as { type?: string; text?: string };
		if (typed.type === "text" && typeof typed.text === "string") {
			parts.push(typed.text);
		} else if (typed.type === "image") {
			imageCount += 1;
		}
	}

	if (imageCount > 0) {
		parts.push(`[${imageCount} image${imageCount === 1 ? "" : "s"}]`);
	}

	return parts.join("");
}

/**
 * Safely stringifies a value to JSON, handling circular references.
 *
 * @param value - The value to stringify
 * @returns JSON string representation, or fallback for unserializable values
 */
export function safeStringify(value: unknown): string {
	if (value === null) {
		return "null";
	}
	if (value === undefined) {
		return "undefined";
	}

	try {
		const seen = new WeakSet();
		return JSON.stringify(
			value,
			(_key, val) => {
				if (typeof val === "object" && val !== null) {
					if (seen.has(val)) {
						return "[Circular]";
					}
					seen.add(val);
				}
				// Handle special values
				if (typeof val === "bigint") {
					return val.toString();
				}
				if (typeof val === "function") {
					return "[Function]";
				}
				if (typeof val === "symbol") {
					return val.toString();
				}
				return val;
			},
			0,
		);
	} catch {
		try {
			return String(value);
		} catch {
			return "[unserializable]";
		}
	}
}
