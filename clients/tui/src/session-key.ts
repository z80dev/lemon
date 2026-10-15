import { createHash } from "node:crypto";

/**
 * Stable per-directory tag, the same recipe `lemon run --continue` uses for its
 * CLI keys (first 16 hex chars of sha256(cwd)). Embedding it in a TUI key lets
 * `--continue` prefer sessions started from the current directory.
 */
export function cwdSessionTag(cwd: string): string {
	return createHash("sha256").update(cwd).digest("hex").slice(0, 16);
}

/**
 * A canonical channel-peer key, not a subagent or a shared main session. With a
 * `cwd` the peer id carries the directory tag (`<tag>-<uuid>`).
 */
export function newSessionKey(cwd?: string): string {
	const peer =
		cwd === undefined ? crypto.randomUUID() : `${cwdSessionTag(cwd)}-${crypto.randomUUID()}`;
	return `agent:default:tui:local:dm:${peer}`;
}

/**
 * Native TUI journals are directory-scoped. A foreign tag or a legacy key
 * without a tag cannot establish the journal's directory, so refuse attachment
 * rather than risk replacing its native history mapping.
 */
export function assertSessionDirectory(key: string, cwd: string): void {
	const peer = /^agent:[^:]+:tui:local:dm:(.+)$/.exec(key)?.[1];
	if (peer === undefined || peer.startsWith(`${cwdSessionTag(cwd)}-`)) return;
	throw new Error(
		"this TUI session belongs to another or unknown directory; reopen it from its original directory",
	);
}
