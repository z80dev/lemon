/**
 * Session commands: listing, switching, lifecycle and history replay.
 *
 * The switcher overlay itself is P6. Until it exists `/sessions` renders the
 * merged list as a picker, which is the same data the switcher will show and
 * degrades to a plain list when the host has no picker mounted.
 */

import { METHOD } from "../protocol/methods.ts";
import type { ChatHistoryMessage, SessionSummary } from "../protocol/types.ts";
import { asArray, asRecord, humanTime, pickNumber, pickString } from "./format.ts";
import type { CommandContext, PickerChoice, SlashCommand } from "./registry.ts";

const HISTORY_DEFAULT = 20;

interface SessionRow {
	key: string;
	agentId?: string;
	active: boolean;
	updatedAtMs?: number;
	runCount?: number;
	local: boolean;
}

/** Merge `sessions.active.list`, `sessions.list` and locally-known sessions. */
export async function collectSessions(ctx: CommandContext): Promise<SessionRow[]> {
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
		});
	};

	if (ctx.methods.supports(METHOD.sessionsActiveList)) {
		const result = await ctx.methods.sessionsActiveList().catch(() => undefined);
		for (const entry of asArray(result?.sessions)) add(entry as SessionSummary, true);
	}
	if (ctx.methods.supports(METHOD.sessionsList)) {
		const result = await ctx.methods.sessionsList().catch(() => undefined);
		for (const entry of asArray(result?.sessions)) add(entry as SessionSummary, false);
	}
	for (const session of ctx.store.sessions.values()) {
		const existing = rows.get(session.key);
		rows.set(session.key, {
			key: session.key,
			agentId: existing?.agentId,
			active: existing?.active ?? session.busy,
			updatedAtMs: existing?.updatedAtMs,
			runCount: existing?.runCount,
			local: true,
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
		row.runCount !== undefined ? `${row.runCount} run(s)` : undefined,
		humanTime(row.updatedAtMs),
	].filter(Boolean);
	return { value: row.key, label: row.key, description: marks.join(" · ") };
}

export const sessionsCommand: SlashCommand = {
	name: "sessions",
	summary: "list sessions and switch between them",
	group: "sessions",
	async run(ctx) {
		const rows = await collectSessions(ctx);
		if (rows.length === 0) {
			ctx.ui.notice("no sessions");
			return;
		}
		if (ctx.ui.openSessionSwitcher) {
			ctx.ui.openSessionSwitcher();
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
	usage: "<new [key] | reset | delete | switch <key> | info>",
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
					`engine: ${session.engine ?? "(daemon default)"}`,
					`thinking: ${session.thinkingLevel ?? "(daemon default)"}`,
					`tool policy: ${session.toolPolicy ?? "(daemon default)"}`,
				]);
				return;
			}
			case "new": {
				const key = argv[1] ?? defaultNewSessionKey();
				if (!ctx.ui.switchSession) {
					ctx.ui.notice("creating sessions needs the switcher (P6)", "warning");
					return;
				}
				await ctx.ui.switchSession(key);
				ctx.ui.notice(`new session ${key}`);
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
				ctx.ui.notice(`reset ${ctx.session.key} (server-side history cleared)`);
				return;
			}
			case "delete": {
				if (!ctx.methods.supports(METHOD.sessionsDelete)) {
					ctx.ui.notice(`daemon does not support ${METHOD.sessionsDelete}`, "warning");
					return;
				}
				const key = argv[1] ?? ctx.session.key;
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

function defaultNewSessionKey(now: Date = new Date()): string {
	return `tui-${now.toISOString().replace(/[-:.]/g, "").slice(0, 15)}`;
}

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
