/**
 * Hermes-compatible command names backed by Lemon control-plane capabilities.
 *
 * These are intentionally thin adapters: Lemon remains authoritative for the
 * data and execution semantics, while the TUI supplies familiar command names
 * and readable, bounded output. Optional methods are capability-gated against
 * the handshake so an older daemon receives no speculative RPCs.
 */

import { METHOD } from "../protocol/methods.ts";
import { asArray, asRecord, humanDuration, humanTime, pickNumber, pickString } from "./format.ts";
import type { CommandContext, SlashCommand } from "./registry.ts";

export const commandsCommand: SlashCommand = {
	name: "commands",
	summary: "browse commands advertised by the daemon",
	usage: "[command]",
	group: "general",
	async run(ctx, argv) {
		if (ctx.methods.supports(METHOD.commandsCatalog)) {
			try {
				const result = await ctx.methods.commandsCatalog();
				const lines = serverCatalogLines(result, argv[0]);
				if (lines.length > 1) {
					ctx.ui.noticeBlock(lines);
					return;
				}
			} catch {
				// Catalog discovery is additive. A local command browser is still
				// useful during rolling upgrades or a transient server failure.
			}
		}
		ctx.ui.noticeBlock(localCatalogLines(ctx, argv[0]));
	},
};

export const agentsCommand: SlashCommand = {
	name: "agents",
	summary: "list agents known to Lemon",
	group: "runs",
	methods: [METHOD.agentsList],
	async run(ctx) {
		const result = await ctx.methods.agentsList();
		const agents = asArray(result.agents);
		if (agents.length === 0) {
			ctx.ui.notice("no agents");
			return;
		}
		const lines = [`agents — ${agents.length}`];
		for (const agent of agents) {
			const id = pickString(agent, "agentId", "id", "name") ?? "?";
			const name = pickString(agent, "name");
			const sessions = pickNumber(agent, "sessionCount") ?? 0;
			const active = pickNumber(agent, "activeSessionCount") ?? 0;
			const description = oneLine(pickString(agent, "description") ?? "", 72);
			lines.push(
				`  ${name && name !== id ? `${name} (${id})` : id} · ${active} active · ${sessions} session(s)${description ? ` — ${description}` : ""}`,
			);
		}
		ctx.ui.noticeBlock(lines);
	},
};

export const tasksCommand: SlashCommand = {
	name: "tasks",
	summary: "list active and recent subagent tasks",
	usage: "[count]",
	group: "runs",
	availableWhen(ctx) {
		if (ctx.methods.supports(METHOD.tasksActiveList)) return true;
		if (ctx.methods.supports(METHOD.tasksRecentList)) return true;
		return "daemon exposes neither tasks.active.list nor tasks.recent.list";
	},
	async run(ctx, argv) {
		const requested = Number.parseInt(argv[0] ?? "", 10);
		const limit = Number.isFinite(requested) && requested > 0 ? Math.min(requested, 50) : 10;
		const lines: string[] = [];
		if (ctx.methods.supports(METHOD.tasksActiveList)) {
			const result = await ctx.methods.tasksActiveList({ limit });
			const tasks = asArray(asRecord(result)?.tasks);
			lines.push(`active tasks: ${tasks.length}`);
			for (const task of tasks) lines.push(`  ${describeTask(task)}`);
		}
		if (ctx.methods.supports(METHOD.tasksRecentList)) {
			const result = await ctx.methods.tasksRecentList({ limit });
			const tasks = asArray(asRecord(result)?.tasks);
			lines.push(`recent tasks: ${tasks.length}`);
			for (const task of tasks) lines.push(`  ${describeTask(task)}`);
		}
		ctx.ui.noticeBlock(lines);
	},
};

export const compressCommand: SlashCommand = {
	name: "compress",
	summary: "compact the current session context",
	group: "sessions",
	methods: [METHOD.sessionsCompact],
	async run(ctx) {
		const result = await ctx.methods.sessionsCompact({ sessionKey: ctx.session.key });
		const before = pickNumber(result, "tokensBefore");
		const after = pickNumber(result, "tokensAfter");
		const tokenChange =
			before !== undefined || after !== undefined
				? ` · ${before ?? "?"} → ${after ?? "?"} tokens`
				: "";
		ctx.ui.notice(`compressed ${ctx.session.key}${tokenChange}`);
	},
};

export const backgroundCommand: SlashCommand = {
	name: "bg",
	summary: "start a background task",
	usage: "<prompt>",
	group: "runs",
	methods: [METHOD.backgroundStart],
	async run(ctx) {
		if (!ctx.rest) {
			ctx.ui.notice("usage: /bg <prompt>", "error");
			return;
		}
		const result = await ctx.methods.backgroundStart({
			prompt: ctx.rest,
			sessionId: ctx.session.key,
			...(ctx.session.model ? { model: ctx.session.model } : {}),
			...(ctx.session.thinkingLevel ? { thinkingLevel: ctx.session.thinkingLevel } : {}),
		});
		const id = pickString(result, "id", "taskId", "runId") ?? "started";
		const status = pickString(result, "status");
		ctx.ui.notice(`background ${id}${status ? ` · ${status}` : ""}`);
	},
};

export const btwCommand: SlashCommand = {
	name: "btw",
	summary: "ask a quick side question without changing the main turn",
	usage: "<question>",
	group: "runs",
	methods: [METHOD.sessionBtw],
	async run(ctx) {
		if (!ctx.rest) {
			ctx.ui.notice("usage: /btw <question>", "error");
			return;
		}
		const result = await ctx.methods.sessionBtw({
			sessionId: ctx.session.key,
			question: ctx.rest,
		});
		const answer = pickString(result, "answer", "response", "text", "result");
		if (answer) ctx.ui.noticeBlock(["btw", answer]);
		else {
			const id = pickString(result, "id", "runId");
			ctx.ui.notice(`btw submitted${id ? ` · ${id}` : ""}`);
		}
	},
};

/** Normalize a daemon catalog without imposing one response version on it. */
export function serverCatalogLines(result: unknown, filter?: string): string[] {
	const record = asRecord(result);
	const rows = asArray(record?.commands ?? record?.items ?? record?.catalog);
	const wanted = filter?.toLowerCase().replace(/^\//, "");
	const matching = wanted
		? rows.filter((row) => {
				const name = pickString(row, "name", "command")?.replace(/^\//, "").toLowerCase();
				const aliases = asArray(asRecord(row)?.aliases).map(String);
				return name === wanted || aliases.some((alias) => alias.replace(/^\//, "") === wanted);
			})
		: rows;
	if (matching.length === 0) return ["commands — daemon catalog"];

	const lines = ["commands — daemon catalog"];
	for (const row of matching) {
		const name = pickString(row, "name", "command")?.replace(/^\//, "");
		if (!name) continue;
		const usage = pickString(row, "usage", "args");
		const summary = pickString(row, "summary", "description", "help") ?? "";
		const aliases = asArray(asRecord(row)?.aliases)
			.map(String)
			.map((alias) => `/${alias.replace(/^\//, "")}`);
		lines.push(
			`  /${name}${usage ? ` ${usage}` : ""}${summary ? ` — ${oneLine(summary)}` : ""}${aliases.length ? ` (aliases: ${aliases.join(", ")})` : ""}`,
		);
	}
	return lines;
}

function localCatalogLines(ctx: CommandContext, filter?: string): string[] {
	const help = ctx.registry.renderHelp(ctx, filter);
	if (filter) return ["commands — local fallback", ...help];
	return ["commands — local fallback", ...help.slice(1)];
}

function describeTask(task: unknown): string {
	const description = oneLine(pickString(task, "description") ?? "", 62);
	return [
		pickString(task, "taskId", "id") ?? "?",
		pickString(task, "status"),
		pickString(task, "agentId"),
		pickString(task, "role"),
		humanDuration(pickNumber(task, "durationMs")),
		humanTime(pickNumber(task, "completedAtMs", "updatedAtMs", "startedAtMs")),
		description,
	]
		.filter(Boolean)
		.join(" · ");
}

function oneLine(text: string, max = 100): string {
	const flat = text.replace(/\s+/g, " ").trim();
	return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
}
