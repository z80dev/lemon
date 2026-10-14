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
