import { homedir } from "node:os";
import { isAbsolute, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { hasControlChars } from "../formatters/base.ts";

export const IMAGE_PATH = /\.(?:png|jpe?g|gif|webp)$/i;

/** Shell-style quoting/escaping only: never execute expansions, globs, or commands. */
export function parsePastedPaths(text: string): string[] | undefined {
	const source = text.trim();
	// biome-ignore lint/suspicious/noControlCharactersInRegex: Reject control bytes while allowing pasted path separators.
	if (!source || source.length > 64 * 1024 || /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(source)) {
		return undefined;
	}
	const tokens: string[] = [];
	let token = "";
	let quotedToken = false;
	const quoted: boolean[] = [];
	let quote = "";
	let escaped = false;
	for (const char of source) {
		if (escaped) {
			token += char;
			escaped = false;
		} else if (char === "\\" && quote !== "'") {
			escaped = true;
		} else if (quote) {
			if (char === quote) quote = "";
			else token += char;
		} else if (char === '"' || char === "'") {
			quotedToken = true;
			quote = char;
		} else if (/\s/.test(char)) {
			if (token) {
				tokens.push(token);
				quoted.push(quotedToken);
			}
			token = "";
			quotedToken = false;
		} else {
			token += char;
		}
	}
	if (escaped || quote) return undefined;
	if (token) {
		tokens.push(token);
		quoted.push(quotedToken);
	}
	if (tokens.length === 0) return undefined;
	// Raw absolute Finder paths may contain spaces without shell quoting.
	if (
		tokens.length > 1 &&
		isAbsolute(source) &&
		IMAGE_PATH.test(source) &&
		!source.includes("\n") &&
		!/["'\\]/.test(source) &&
		tokens.slice(1).some((value) => !/^(?:\/|~\/|\.{1,2}\/|file:\/\/)/.test(value))
	) {
		return [source];
	}
	const paths: string[] = [];
	try {
		for (const [index, value] of tokens.entries()) {
			if (/^[a-z][a-z\d+.-]*:\/\//i.test(value) && !value.startsWith("file://")) return undefined;
			const path = value.startsWith("file://") ? fileURLToPath(value) : value;
			// A pasted slash command is not a drag of a root-level file.
			if (!quoted[index] && /^\/[^/.]+$/.test(path)) return undefined;
			if (
				!isAbsolute(path) &&
				!path.startsWith("~/") &&
				!path.startsWith("./") &&
				!path.startsWith("../") &&
				!/^[^\s]+\/[^\s]+$/.test(path) &&
				!IMAGE_PATH.test(path) &&
				!(quoted[index] && /[/.]/.test(path))
			) {
				return undefined;
			}
			if (hasControlChars(path)) return undefined;
			paths.push(path);
		}
	} catch {
		// Remote file URLs, malformed percent escapes, etc. remain ordinary text.
		return undefined;
	}
	return paths;
}

export function resolvePastedPath(path: string, cwd: string): string {
	return resolve(cwd, path.startsWith("~/") ? `${homedir()}/${path.slice(2)}` : path);
}

/** A mention is a reference for the agent to read, never implicit file ingestion. */
export function fileMention(path: string): string {
	return `@${/[\s"'\\]/.test(path) ? JSON.stringify(path) : path}`;
}
