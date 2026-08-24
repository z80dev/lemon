/**
 * Session commands: listing, switching, lifecycle and history replay.
 *
 * The switcher overlay itself is P6. Until it exists `/sessions` renders the
 * merged list as a picker, which is the same data the switcher will show and
 * degrades to a plain list when the host has no picker mounted.
 */

import type { ControlPlaneMethods } from "../protocol/methods.ts";
import { METHOD } from "../protocol/methods.ts";
import type { ChatHistoryMessage, SessionSummary } from "../protocol/types.ts";
import type { AppStore } from "../store/app-store.ts";
import { asArray, asRecord, humanTime, pickNumber, pickString } from "./format.ts";
import type { CommandContext, PickerChoice, SlashCommand } from "./registry.ts";

const HISTORY_DEFAULT = 20;

/** How many stored sessions the merged list asks for. */
export const SESSION_LIST_LIMIT = 100;

export interface SessionRow {
	key: string;
	agentId?: string;
	/** Running server-side, or busy in this client. */
	active: boolean;
	updatedAtMs?: number;
	runCount?: number;
	/** This client has a transcript for it. */
	local: boolean;
	/** Blocks that arrived while it was off screen. */
	unread: number;
	model?: string;
}

/** What the merge needs; {@link CommandContext} satisfies it structurally. */
export interface SessionSource {
	store: AppStore;
	methods: ControlPlaneMethods;
}

/**
 * Merge `sessions.active.list`, `sessions.list` and locally-known sessions into
 * one list, newest first with live sessions on top. Both remote calls are
 * best-effort: a daemon that cannot answer one still produces a usable list from
 * the others, which is what keeps the switcher openable while reconnecting.
 */
export async function collectSessions(source: SessionSource): Promise<SessionRow[]> {
	const rows = new Map<string, SessionRow>();
	const add = (summary: SessionSummary, active: boolean) => {
		const key = pickString(summary, "sessionKey", "session_key", "key");
		if (!key) return;
		const existing = rows.get(key);
		rows.set(key, {
			key,
			agentId: pickString(summary, "agentId") ?? existing?.agentId,
			active: active || (existing?.active ?? false),
			updatedAtMs: pickNumber(summary, "updatedAtMs") ?? existing?.updatedAtMs,
			runCount: pickNumber(summary, "runCount") ?? existing?.runCount,
			local: existing?.local ?? false,
			unread: existing?.unread ?? 0,
			model: pickString(summary, "model") ?? existing?.model,
		});
	};

	if (source.methods.supports(METHOD.sessionsActiveList)) {
		const result = await source.methods.sessionsActiveList().catch(() => undefined);
		for (const entry of asArray(result?.sessions)) add(entry as SessionSummary, true);
	}
	if (source.methods.supports(METHOD.sessionsList)) {
		const result = await source.methods
			.sessionsList({ limit: SESSION_LIST_LIMIT })
			.catch(() => undefined);
		for (const entry of asArray(result?.sessions)) add(entry as SessionSummary, false);
	}
	for (const session of source.store.sessions.values()) {
		const existing = rows.get(session.key);
		rows.set(session.key, {
			key: session.key,
			agentId: existing?.agentId,
			active: session.busy || (existing?.active ?? false),
			// A locally-known session's last block is a better "when" than a
			// remote timestamp the daemon may only refresh on completion.
			updatedAtMs: Math.max(existing?.updatedAtMs ?? 0, session.lastBlock?.at ?? 0) || undefined,
			runCount: existing?.runCount,
			local: true,
			unread: session.unread,
			model: session.model ?? existing?.model,
		});
	}
	return [...rows.values()].sort((left, right) => {
		if (left.active !== right.active) return left.active ? -1 : 1;
		return (right.updatedAtMs ?? 0) - (left.updatedAtMs ?? 0);
	});
}

function describeRow(row: SessionRow, focusedKey: string): PickerChoice {
	const marks = [
		row.key === focusedKey ? "current" : undefined,
		row.active ? "active" : undefined,
		row.local ? "local" : undefined,
		row.unread > 0 ? `${row.unread} unread` : undefined,
		row.runCount !== undefined ? `${row.runCount} run(s)` : undefined,
		humanTime(row.updatedAtMs),
	].filter(Boolean);
	return { value: row.key, label: row.key, description: marks.join(" · ") };
}

export const sessionsCommand: SlashCommand = {
	name: "sessions",
	summary: "list sessions and switch between them (also Ctrl+X)",
	group: "sessions",
	async run(ctx) {
		// The switcher shows the same merged list with the lifecycle keys bound,
		// so it wins whenever the UI has one mounted.
		if (ctx.ui.openSessionSwitcher) {
			ctx.ui.openSessionSwitcher();
			return;
		}
		const rows = await collectSessions(ctx);
		if (rows.length === 0) {
			ctx.ui.notice("no sessions");
			return;
		}
		const items = rows.map((row) => describeRow(row, ctx.store.focusedKey));
		ctx.ui.openPicker({
			title: "sessions",
			items,
			footer: "enter switches · esc cancels",
			onSelect: async (choice) => {
				await switchTo(ctx, choice.value);
			},
		});
	},
};

async function switchTo(ctx: CommandContext, key: string): Promise<void> {
	if (key === ctx.store.focusedKey) {
		ctx.ui.notice(`already on ${key}`);
		return;
	}
	if (!ctx.ui.switchSession) {
		// P6 owns the switch (draft persistence, cold hydration, scrollback).
		ctx.ui.notice(`session switching arrives with the switcher; ${key} is not focused`, "warning");
		return;
	}
	await ctx.ui.switchSession(key);
}

export const sessionCommand: SlashCommand = {
	name: "session",
	summary: "session lifecycle",
	usage: "<new [key] [prompt…] | reset | delete [key] | switch <key> | info>",
	group: "sessions",
	async run(ctx, argv) {
		const action = (argv[0] ?? "info").toLowerCase();
		switch (action) {
			case "info": {
				const session = ctx.session;
				ctx.ui.noticeBlock([
					`session ${session.key}`,
					`blocks: ${session.blocks.length} · unread: ${session.unread}`,
					`busy: ${session.busy}${session.activeRunId ? ` (run ${session.activeRunId})` : ""}`,
					`model: ${session.model ?? "(daemon default)"}`,
					`native runtime: ${session.engine ?? "(not reported)"}`,
					`thinking: ${session.thinkingLevel ?? "(daemon default)"}`,
					`tool policy: ${session.toolPolicy ?? "(daemon default)"}`,
				]);
				return;
			}
			case "new": {
				// `/session new [key] [first prompt…]` — everything past the key is
				// the first message, which is also what mints the session daemon-side.
				const key = argv[1];
				const prompt = argv.slice(2).join(" ").trim();
				if (!ctx.ui.createSession) {
					ctx.ui.notice("this build cannot create sessions", "warning");
					return;
				}
				await ctx.ui.createSession(key, prompt.length > 0 ? prompt : undefined);
				ctx.ui.notice(`new session ${ctx.store.focusedKey}`);
				return;
			}
			case "switch": {
				const key = argv[1];
				if (!key) {
					ctx.ui.notice("usage: /session switch <key>", "error");
					return;
				}
				await switchTo(ctx, key);
				return;
			}
			case "reset": {
				if (!ctx.methods.supports(METHOD.sessionsReset)) {
					ctx.ui.notice(`daemon does not support ${METHOD.sessionsReset}`, "warning");
					return;
				}
				await ctx.methods.sessionsReset({ sessionKey: ctx.session.key });
				// Both sides forget together: a cleared server history under a
				// transcript still on screen is a session the user cannot reason
				// about, and the next switch would rebuild the stale half.
				ctx.ui.resetSession?.(ctx.session.key);
				ctx.ui.notice(`reset ${ctx.session.key} (history cleared here and on the daemon)`);
				return;
			}
			case "delete":
			case "close": {
				const key = argv[1] ?? ctx.session.key;
				if (ctx.ui.closeSession) {
					// The host asks for confirmation in an overlay.
					await ctx.ui.closeSession(key);
					return;
				}
				if (!ctx.methods.supports(METHOD.sessionsDelete)) {
					ctx.ui.notice(`daemon does not support ${METHOD.sessionsDelete}`, "warning");
					return;
				}
				// Deleting a session throws away server-side history, so the user
				// has to name it: `/session delete` alone only asks.
				if (argv[1] === undefined) {
					ctx.ui.notice(
						`/session delete ${key} — repeat with the key to confirm deleting its history`,
						"warning",
					);
					return;
				}
				await ctx.methods.sessionsDelete({ sessionKey: key });
				ctx.ui.notice(`deleted ${key}`, "warning");
				return;
			}
			default:
				ctx.ui.notice(`usage: /session ${sessionCommand.usage}`, "error");
		}
	},
};

export const resumeCommand: SlashCommand = {
	name: "resume",
	summary: "replay a session's stored history into the transcript",
	usage: "[key] [count]",
	group: "sessions",
	methods: [METHOD.chatHistory],
	async run(ctx, argv) {
		const key = argv[0] && !/^\d+$/.test(argv[0]) ? argv[0] : ctx.session.key;
		const countArg = argv.find((arg) => /^\d+$/.test(arg));
		const limit = countArg ? Math.min(Number.parseInt(countArg, 10), 200) : 50;
		// Resuming another session is a switch, and the switch already hydrates
		// from stored history — replaying it into *this* transcript instead would
		// mix two sessions' messages under one key.
		if (key !== ctx.session.key && ctx.ui.switchSession) {
			await ctx.ui.switchSession(key);
			ctx.ui.notice(`switched to ${key}`);
			return;
		}
		const result = await ctx.methods.chatHistory({
			sessionKey: key,
			limit,
			includeFullText: true,
		});
		const messages = (result?.messages ?? []) as ChatHistoryMessage[];
		if (messages.length === 0) {
			ctx.ui.notice(`no stored history for ${key}`);
			return;
		}
		ctx.ui.replayHistory(messages);
		ctx.ui.notice(`replayed ${messages.length} message(s) from ${key}`);
	},
};

export const historyCommand: SlashCommand = {
	name: "history",
	summary: "summarize recent messages without replaying them",
	usage: "[count]",
	group: "sessions",
	methods: [METHOD.chatHistory],
	async run(ctx, argv) {
		const requested = Number.parseInt(argv[0] ?? "", 10);
		const limit =
			Number.isFinite(requested) && requested > 0 ? Math.min(requested, 200) : HISTORY_DEFAULT;
		const result = await ctx.methods.chatHistory({
			sessionKey: ctx.session.key,
			limit,
			includeFullText: false,
		});
		const messages = (result?.messages ?? []) as ChatHistoryMessage[];
		if (messages.length === 0) {
			ctx.ui.notice(`no stored history for ${ctx.session.key}`);
			return;
		}
		const lines = [`history of ${ctx.session.key} — last ${messages.length}`];
		for (const message of messages) {
			const when = humanTime(message.timestampMs ?? undefined);
			const body = oneLine(message.content ?? "");
			lines.push(`${when ? `${when} ` : ""}${message.role}: ${body}`);
		}
		ctx.ui.noticeBlock(lines);
	},
};

/** Collapse a message to a single readable line for list output. */
function oneLine(text: string, max = 100): string {
	const flat = text.replace(/\s+/g, " ").trim();
	return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
}

/** Exported for tests: the shape `/sessions` turns a summary into. */
export function sessionRowsFrom(result: unknown): SessionSummary[] {
	return asArray(asRecord(result)?.sessions) as SessionSummary[];
}
