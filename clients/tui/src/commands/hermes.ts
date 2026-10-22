/**
 * Hermes-compatible command names backed by Lemon control-plane capabilities.
 *
 * These are intentionally thin adapters: Lemon remains authoritative for the
 * data and execution semantics, while the TUI supplies familiar command names
 * and readable, bounded output. Optional methods are capability-gated against
 * the handshake so an older daemon receives no speculative RPCs.
 */

import { ControlPlaneError, NotConnectedError } from "../protocol/errors.ts";
import { METHOD } from "../protocol/methods.ts";
import {
	asArray,
	asRecord,
	humanDuration,
	humanTime,
	pick,
	pickNumber,
	pickString,
} from "./format.ts";
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
	aliases: ["compact"],
	summary: "compact the current session context",
	usage: "[focus instructions…]",
	group: "sessions",
	methods: [METHOD.sessionsCompact],
	async run(ctx) {
		try {
			const result = await ctx.methods.sessionsCompact({
				sessionKey: ctx.session.key,
				cwd: ctx.cwd ?? process.cwd(),
				...(ctx.rest.trim() ? { focus: ctx.rest.trim() } : {}),
			});
			if (result.success !== true) {
				ctx.ui.notice(
					"compaction was not confirmed; inspect session status before retrying",
					"error",
				);
				return;
			}
			const before = pickNumber(result, "tokensBefore");
			const after = pickNumber(result, "tokensAfter");
			const tokenChange =
				before !== undefined || after !== undefined
					? ` · ${before ?? "?"} → ${after ?? "?"} tokens`
					: "";
			ctx.ui.notice(`compressed ${ctx.session.key}${tokenChange}`, "info", {
				...(before !== undefined ? { tokensBefore: before } : {}),
				...(after !== undefined ? { tokensAfter: after } : {}),
			});
		} catch (error) {
			const code =
				error instanceof ControlPlaneError || error instanceof NotConnectedError
					? error.code
					: "OUTCOME_UNKNOWN";
			ctx.ui.notice(
				`compaction did not complete (${code}); inspect session status before retrying`,
				"error",
			);
		}
	},
};

/**
 * The per-agent heartbeat is an ordinary cron job flagged `meta.heartbeat`.
 * Its results are delivered like any cron result, except a reply of exactly
 * `HEARTBEAT_OK` means "nothing to report" and is suppressed server-side.
 */
export const heartbeatCommand: SlashCommand = {
	name: "heartbeat",
	aliases: ["hb"],
	summary:
		"schedule this agent's recurring check-in; results reach your paired Telegram chat and HEARTBEAT_OK replies are suppressed",
	usage: "[every <interval> <prompt> | status | pause | resume | clear]",
	group: "sessions",
	methods: [
		METHOD.cronList,
		METHOD.cronAdd,
		METHOD.cronUpdate,
		METHOD.cronPause,
		METHOD.cronResume,
		METHOD.cronRemove,
	],
	async run(ctx) {
		const arg = ctx.rest.trim();
		const lower = arg.toLowerCase();
		// Profile main sessions carry their agent in the key; every other TUI
		// session routes to the default agent.
		const agentId = ctx.session.key.match(/^agent:([^:]+):/)?.[1] ?? "default";

		if (!arg || lower === "status") {
			const job = await findHeartbeatJob(ctx, agentId, true);
			ctx.ui.noticeBlock(
				job ? heartbeatJobLines(job) : [`no heartbeat is configured for agent ${agentId}`],
			);
			return;
		}

		if (["pause", "resume", "clear", "stop", "off"].includes(lower)) {
			const id = pickString(await findHeartbeatJob(ctx, agentId, false), "id");
			if (!id) {
				ctx.ui.notice(`no heartbeat is configured for agent ${agentId}`, "warning");
				return;
			}
			if (lower === "pause") {
				await ctx.methods.cronPause({ id });
				ctx.ui.notice(`heartbeat paused · agent ${agentId}`);
			} else if (lower === "resume") {
				const result = await ctx.methods.cronResume({ id });
				const nextRun = humanTime(pickNumber(result, "nextRunAtMs"));
				ctx.ui.notice(
					`heartbeat resumed · agent ${agentId}${nextRun ? ` · next run ${nextRun}` : ""}`,
				);
			} else {
				await ctx.methods.cronRemove({ id });
				ctx.ui.notice(`heartbeat cleared · agent ${agentId}`);
			}
			return;
		}

		const parsed = parseHeartbeatSet(arg);
		if (!parsed) {
			ctx.ui.notice(`usage: /heartbeat ${heartbeatCommand.usage}`, "error");
			return;
		}
		if ("error" in parsed) {
			ctx.ui.notice(parsed.error, "error");
			return;
		}

		const existingId = pickString(await findHeartbeatJob(ctx, agentId, false), "id");
		const result = existingId
			? await ctx.methods.cronUpdate({
					id: existingId,
					schedule: parsed.schedule,
					prompt: parsed.prompt,
					timezone: "local",
					enabled: true,
				})
			: await ctx.methods.cronAdd({
					name: `heartbeat-${agentId}`,
					schedule: parsed.schedule,
					agentId,
					sessionKey: `agent:${agentId}:main`,
					prompt: parsed.prompt,
					timezone: "local",
					meta: { heartbeat: true, agent_id: agentId },
				});
		const nextRun = humanTime(pickNumber(result, "nextRunAtMs"));
		ctx.ui.noticeBlock([
			`heartbeat ${existingId ? "updated" : "set"} · ${parsed.schedule} · agent ${agentId}${nextRun ? ` · next run ${nextRun}` : ""}`,
			parsed.prompt,
			HEARTBEAT_DELIVERY_NOTE,
		]);
	},
};

export const backgroundCommand: SlashCommand = {
	name: "bg",
	summary: "start and manage background tasks",
	usage: "<prompt> | start <prompt> | list [status] | status <id> | result <id> | cancel <id>",
	group: "runs",
	availableWhen(ctx) {
		return BACKGROUND_METHODS.some((method) => ctx.methods.supports(method))
			? true
			: "daemon does not expose background command methods";
	},
	async run(ctx, argv) {
		if (!ctx.rest) {
			ctx.ui.notice(`usage: /bg ${backgroundCommand.usage}`, "error");
			return;
		}

		const action = argv[0]?.toLowerCase();
		switch (action) {
			case "list":
				await listBackgroundRuns(ctx, argv[1]);
				return;
			case "status":
				await showBackgroundStatus(ctx, requiredBackgroundId(ctx, argv[1], "status"));
				return;
			case "result":
				await showBackgroundResult(ctx, requiredBackgroundId(ctx, argv[1], "result"));
				return;
			case "cancel":
				await cancelBackgroundRun(ctx, requiredBackgroundId(ctx, argv[1], "cancel"));
				return;
			case "start":
				await startBackgroundRun(ctx, restAfterFirstWord(ctx.rest));
				return;
			default:
				await startBackgroundRun(ctx, ctx.rest);
		}
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
			sessionKey: ctx.session.key,
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
	const rows = asArray(record?.commands ?? record?.items ?? record?.catalog).filter((row) => {
		const surfaces = asRecord(row)?.surfaces;
		return !Array.isArray(surfaces) || surfaces.includes("tui");
	});
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
		const usage = pickString(row, "arguments", "usage", "args");
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

const BACKGROUND_METHODS = [
	METHOD.backgroundStart,
	METHOD.backgroundList,
	METHOD.backgroundStatus,
	METHOD.backgroundResult,
	METHOD.backgroundCancel,
] as const;

async function startBackgroundRun(ctx: CommandContext, prompt: string): Promise<void> {
	if (!prompt) {
		ctx.ui.notice("usage: /bg start <prompt>", "error");
		return;
	}
	if (!requireMethod(ctx, METHOD.backgroundStart)) return;
	const result = await ctx.methods.backgroundStart({
		prompt,
		sessionKey: ctx.session.key,
		...(ctx.cwd ? { cwd: ctx.cwd } : {}),
		...(ctx.session.model ? { model: ctx.session.model } : {}),
		...(ctx.session.thinkingLevel ? { thinkingLevel: ctx.session.thinkingLevel } : {}),
	});
	const id = pickString(result, "id", "taskId", "runId") ?? "(id unavailable)";
	const status = pickString(result, "status");
	ctx.ui.noticeBlock([
		`background ${status ?? "started"}`,
		`id: ${id}`,
		`inspect: /bg status ${id} · result: /bg result ${id} · cancel: /bg cancel ${id}`,
	]);
}

async function listBackgroundRuns(ctx: CommandContext, status?: string): Promise<void> {
	if (!requireMethod(ctx, METHOD.backgroundList)) return;
	const result = await ctx.methods.backgroundList(status ? { status } : undefined);
	const runs = asArray(result.runs);
	if (runs.length === 0) {
		ctx.ui.notice(`no background tasks${status ? ` with status ${status}` : ""}`);
		return;
	}
	const lines = [`background tasks — ${runs.length}${status ? ` · ${status}` : ""}`];
	for (const run of runs) lines.push(`  ${describeBackgroundRun(run)}`);
	ctx.ui.noticeBlock(lines);
}

async function showBackgroundStatus(ctx: CommandContext, id: string | undefined): Promise<void> {
	if (!id || !requireMethod(ctx, METHOD.backgroundStatus)) return;
	const result = await ctx.methods.backgroundStatus({ id });
	ctx.ui.noticeBlock(backgroundStatusLines(result, id));
}

async function showBackgroundResult(ctx: CommandContext, id: string | undefined): Promise<void> {
	if (!id || !requireMethod(ctx, METHOD.backgroundResult)) return;
	const result = await ctx.methods.backgroundResult({ id });
	if (result.ready !== true) {
		ctx.ui.noticeBlock(["background result not ready", `id: ${id}`]);
		return;
	}
	const answer = pickString(result, "answer") ?? "(empty result)";
	ctx.ui.noticeBlock(["background result", `id: ${id}`, answer]);
}

async function cancelBackgroundRun(ctx: CommandContext, id: string | undefined): Promise<void> {
	if (!id || !requireMethod(ctx, METHOD.backgroundCancel)) return;
	const result = await ctx.methods.backgroundCancel({ id });
	ctx.ui.notice(`background ${id} ${result.cancelled === true ? "cancelled" : "cancel requested"}`);
}

function requiredBackgroundId(
	ctx: CommandContext,
	id: string | undefined,
	action: "status" | "result" | "cancel",
): string | undefined {
	if (id) return id;
	ctx.ui.notice(`usage: /bg ${action} <id>`, "error");
	return undefined;
}

function requireMethod(ctx: CommandContext, method: (typeof BACKGROUND_METHODS)[number]): boolean {
	if (ctx.methods.supports(method)) return true;
	ctx.ui.notice(
		`/${backgroundCommand.name} is unavailable: daemon does not support ${method}`,
		"warning",
	);
	return false;
}

function backgroundStatusLines(result: unknown, fallbackId: string): string[] {
	const id = pickString(result, "id") ?? fallbackId;
	const lines = ["background status", `id: ${id}`];
	const fields = [
		["status", pickString(result, "status")],
		["session", pickString(result, "session_id", "sessionId")],
		["parent", pickString(result, "parent_session_key", "parentSessionKey")],
		[
			"result",
			result && typeof result === "object" && "result_available" in result
				? (result as { result_available?: unknown }).result_available === true
					? "available"
					: "not ready"
				: undefined,
		],
		["updated", humanTime(pickNumber(result, "updated_at", "updatedAtMs"))],
		["error", pickString(result, "error")],
	] as const;
	for (const [label, value] of fields) if (value) lines.push(`${label}: ${value}`);
	return lines;
}

function describeBackgroundRun(run: unknown): string {
	return [
		pickString(run, "id") ?? "?",
		pickString(run, "status"),
		pickString(run, "parent_session_key", "parentSessionKey"),
		humanTime(pickNumber(run, "updated_at", "updatedAtMs")),
	]
		.filter(Boolean)
		.join(" · ");
}

function restAfterFirstWord(text: string): string {
	return text.replace(/^\S+\s*/, "").trim();
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

const HEARTBEAT_DELIVERY_NOTE =
	"results reach your paired Telegram chat; a reply of exactly HEARTBEAT_OK is suppressed";

const HEARTBEAT_UNIT_SECONDS: Record<string, number> = {
	s: 1,
	sec: 1,
	secs: 1,
	second: 1,
	seconds: 1,
	m: 60,
	min: 60,
	mins: 60,
	minute: 60,
	minutes: 60,
	h: 3600,
	hr: 3600,
	hrs: 3600,
	hour: 3600,
	hours: 3600,
	d: 86400,
	day: 86400,
	days: 86400,
};

/**
 * Parse `[every] <n><unit> <prompt>` into a cron shorthand the daemon's
 * scheduler accepts. Heartbeats run on cron-exact intervals only: minutes that
 * divide an hour, hours that divide a day, or exactly one day.
 */
function parseHeartbeatSet(
	text: string,
): { schedule: string; prompt: string } | { error: string } | undefined {
	const match = text.match(
		/^\s*(?:every\s+)?(\d+(?:\.\d+)?)\s*(s|secs?|seconds?|m|mins?|minutes?|h|hrs?|hours?|d|days?)\s+([\s\S]+)$/i,
	);
	if (!match) return undefined;
	const prompt = match[3].trim();
	const unitSeconds = HEARTBEAT_UNIT_SECONDS[match[2].toLowerCase()];
	const seconds = Number.parseFloat(match[1]) * unitSeconds;
	if (!prompt || !Number.isFinite(seconds)) return undefined;

	const requested = `${match[1]}${match[2].toLowerCase()}`;
	if (seconds < 60) {
		return { error: `heartbeat interval ${requested} is too small — minimum is 1m` };
	}
	if (seconds === 86400) return { schedule: "daily", prompt };
	const hours = seconds / 3600;
	if (Number.isInteger(hours) && hours < 24 && 24 % hours === 0) {
		return { schedule: `every ${hours}h`, prompt };
	}
	const minutes = seconds / 60;
	if (Number.isInteger(minutes) && minutes < 60 && 60 % minutes === 0) {
		return { schedule: `every ${minutes}m`, prompt };
	}
	return {
		error: `heartbeat interval ${requested} is not cron-exact — use minutes that divide 60, hours that divide 24, or 1d`,
	};
}

/** The agent's heartbeat job, found by its `meta.heartbeat` flag. */
async function findHeartbeatJob(
	ctx: CommandContext,
	agentId: string,
	includeTargetText: boolean,
): Promise<unknown> {
	const result = await ctx.methods.cronList({ agentId, includeTargetText });
	return asArray(result.jobs).find(
		(job) =>
			pick(job, "meta.heartbeat") === true &&
			pickString(job, "meta.agent_id", "meta.agentId", "agentId") === agentId,
	);
}

function heartbeatJobLines(job: unknown): string[] {
	const enabled = pick(job, "enabled") === true;
	const timezone = pickString(job, "timezone") ?? "UTC";
	const nextRun = enabled ? humanTime(pickNumber(job, "nextRunAtMs")) : undefined;
	const lastRun = humanTime(pickNumber(job, "lastRunAtMs"));
	const lastStatus = pickString(job, "lastRunStatus");
	const lines = [
		`heartbeat · ${enabled ? "enabled" : "paused"} · ${pickString(job, "schedule") ?? "?"} (${timezone}) · agent ${pickString(job, "agentId") ?? "?"}`,
	];
	if (nextRun) lines.push(`next run: ${nextRun}`);
	if (lastRun) lines.push(`last run: ${lastRun}${lastStatus ? ` · ${lastStatus}` : ""}`);
	const prompt = pickString(job, "prompt");
	if (prompt) lines.push(prompt);
	lines.push(HEARTBEAT_DELIVERY_NOTE);
	return lines;
}
