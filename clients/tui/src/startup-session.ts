/**
 * Startup session selection for `--continue` and `--resume [key]`.
 *
 * The selection itself is a pure function over `sessions.list` rows so it can
 * be tested without a daemon; {@link resolveStartup} is the thin I/O wrapper.
 */

import { pickNumber, pickString } from "./commands/format.ts";
import type { ControlPlaneMethods } from "./protocol/methods.ts";
import type { SessionSummary } from "./protocol/types.ts";
import { cwdSessionTag } from "./session-key.ts";
import type { NoticeLevel } from "./store/transcript-model.ts";

/** What the command line asked for at startup. */
export type StartupRequest =
	/** Attach to this directory's most recently updated TUI session. */
	| { mode: "continue" }
	/** With a key: attach if it exists. Without: open the session switcher. */
	| { mode: "resume"; key?: string };

export interface StartupResolution {
	/** The session to focus; undefined keeps the fresh key the shell minted. */
	sessionKey?: string;
	/** Open the session switcher once the session is loaded. */
	openSwitcher?: boolean;
	notice?: { text: string; level: NoticeLevel };
}

/** The server maximum page; matches the exact-key lookups in `/session`. */
const LIST_PAGE = 500;
/** Rows inspected at most; a runaway daemon cannot stall startup. */
const LIST_CAP = 5000;

const TUI_LOCAL_DM = ":tui:local:dm:";

/**
 * Key of the newest non-archived local TUI session started from `cwd`.
 *
 * A key belongs to `cwd` when its peer id starts with the directory tag minted
 * by `newSessionKey(cwd)`. Native history is stored per directory, so a session
 * from another directory (or an older untagged key, whose directory is unknown)
 * is never continued: attaching it here would show its transcript while the
 * model starts without its history. `exclude` removes the key the shell minted
 * for itself, which is never a session to continue.
 */
export function selectContinueSession(
	rows: readonly SessionSummary[],
	options: { cwd: string; exclude?: string },
): string | undefined {
	const marker = `${TUI_LOCAL_DM}${cwdSessionTag(options.cwd)}-`;
	let best: string | undefined;
	let bestAt = -1;
	for (const row of rows) {
		const key = pickString(row, "sessionKey", "session_key", "key");
		if (!key || key === options.exclude || row.archived === true) continue;
		if (!key.includes(marker)) continue;
		const at = pickNumber(row, "updatedAtMs") ?? 0;
		if (best !== undefined && at <= bestAt) continue;
		best = key;
		bestAt = at;
	}
	return best;
}

async function listAll(methods: ControlPlaneMethods): Promise<SessionSummary[]> {
	const rows: SessionSummary[] = [];
	while (rows.length < LIST_CAP) {
		const page = await methods.sessionsList({
			limit: LIST_PAGE,
			offset: rows.length,
			archived: false,
		});
		const batch = (page.sessions ?? []) as SessionSummary[];
		rows.push(...batch);
		if (batch.length === 0 || rows.length >= (page.total ?? 0)) break;
	}
	return rows;
}

function describeError(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

export async function resolveStartup(
	request: StartupRequest,
	deps: { methods: ControlPlaneMethods; cwd: string; currentKey: string },
): Promise<StartupResolution> {
	const { methods } = deps;
	if (request.mode === "resume" && request.key === undefined) return { openSwitcher: true };

	if (request.mode === "resume") {
		const key = request.key as string;
		try {
			const result = await methods.sessionsList({ query: key, limit: LIST_PAGE });
			const found = ((result.sessions ?? []) as SessionSummary[]).some(
				(row) => pickString(row, "sessionKey", "session_key", "key") === key,
			);
			if (found) return { sessionKey: key };
			return {
				notice: {
					text: `session ${key} was not found — started a new session (open /sessions to browse)`,
					level: "warning",
				},
			};
		} catch (error) {
			return {
				sessionKey: key,
				notice: {
					text: `could not verify session ${key} (${describeError(error)}) — attaching anyway`,
					level: "warning",
				},
			};
		}
	}

	try {
		const sessionKey = selectContinueSession(await listAll(methods), {
			cwd: deps.cwd,
			exclude: deps.currentKey,
		});
		if (!sessionKey) {
			return {
				notice: {
					text: "no previous session for this directory — started a new one",
					level: "info",
				},
			};
		}
		return {
			sessionKey,
			notice: {
				text: `continuing the latest session for this directory · ${sessionKey}`,
				level: "info",
			},
		};
	} catch (error) {
		return {
			notice: {
				text: `could not look up a session to continue (${describeError(error)}) — started a new one`,
				level: "error",
			},
		};
	}
}
