/**
 * Read-only views of the daemon: health, usage, cost, logs.
 *
 * Every payload here is rendered field-by-field where the shape is known and
 * falls back to a shallow dump where it is not, so a daemon that adds a section
 * shows it rather than hiding it behind a client that never learned about it.
 */

import { METHOD } from "../protocol/methods.ts";
import {
	asArray,
	asRecord,
	humanCost,
	humanDuration,
	humanNumber,
	keyValueLines,
	pickBoolean,
	pickNumber,
	pickString,
	shallowLines,
} from "./format.ts";
import type { SlashCommand } from "./registry.ts";

export const statusCommand: SlashCommand = {
	name: "status",
	summary: "daemon status and health",
	group: "diagnostics",
	methods: [METHOD.status],
	async run(ctx) {
		const status = await ctx.methods.status();
		const lines: string[] = [];
		const server = asRecord(status.server);
		const connections = asRecord(status.connections);
		const runs = asRecord(status.runs);
		const channels = asRecord(status.channels);
		const skills = asRecord(status.skills);

		lines.push(
			`lemon ${pickString(server, "version") ?? "?"} · ${ctx.client.url} · ${ctx.client.state}`,
		);
		lines.push(
			...keyValueLines([
				["uptime", humanDuration(pickNumber(server, "uptime_ms", "uptimeMs"))],
				[
					"memory",
					pickNumber(server, "memory_mb", "memoryMb")
						? `${pickNumber(server, "memory_mb", "memoryMb")} MB`
						: undefined,
				],
				["otp", pickString(server, "otp_release")],
				[
					"connections",
					connections
						? `${pickNumber(connections, "active") ?? 0} active, ${pickNumber(connections, "operators") ?? 0} operator(s)`
						: undefined,
				],
				[
					"runs",
					runs
						? `${pickNumber(runs, "active") ?? 0} active, ${pickNumber(runs, "queued") ?? 0} queued, ${pickNumber(runs, "completed_today") ?? 0} today`
						: undefined,
				],
				[
					"channels",
					channels ? `${asArray(channels.connected).join(", ") || "none"} connected` : undefined,
				],
				[
					"skills",
					skills
						? `${pickNumber(skills, "enabled") ?? 0}/${pickNumber(skills, "installed") ?? 0} enabled`
						: undefined,
				],
			]),
		);

		if (ctx.methods.supports(METHOD.health)) {
			const health = await ctx.methods.health().catch(() => undefined);
			if (health) {
				// `health.ok` is a boolean; "health: true" reads like a bug.
				const flag = pickBoolean(health, "ok");
				const ok =
					flag === undefined
						? pickString(health, "status", "summary.status")
						: flag
							? "ok"
							: "degraded";
				lines.push(`health: ${ok ?? "reported"}`);
				const checks = asRecord(health.checks);
				if (checks) {
					for (const [name, value] of Object.entries(checks)) {
						lines.push(`  ${name}: ${pickString(value, "status", "ok") ?? String(value)}`);
					}
				}
			}
		}

		lines.push(
			`session ${ctx.session.key} · ${ctx.session.busy ? "busy" : "idle"} · ${ctx.store.sessions.size} known locally`,
		);
		ctx.ui.noticeBlock(lines);
	},
};

export const usageCommand: SlashCommand = {
	name: "usage",
	summary: "token and quota usage",
	group: "diagnostics",
	methods: [METHOD.usageStatus],
	async run(ctx) {
		const usage = await ctx.methods.usageStatus();
		ctx.store.usage = usage as Record<string, unknown>;
		ctx.ui.refreshStatus();
		const input = pickNumber(usage, "tokens.input") ?? 0;
		const output = pickNumber(usage, "tokens.output") ?? 0;
		const lines = [
			`usage — ${pickString(usage, "period") ?? "today"}`,
			...keyValueLines([
				["runs", pickNumber(usage, "runs")],
				[
					"tokens",
					`${humanNumber(input)} in · ${humanNumber(output)} out · ${humanNumber(input + output)} total`,
				],
				["cost", humanCost(pickNumber(usage, "cost"))],
				["status", pickString(usage, "summary.status")],
				["remaining runs", pickNumber(usage, "summary.remainingRuns")],
				["remaining tokens", pickNumber(usage, "summary.remainingTokens")],
			]),
		];
		const providers = asArray(usage.providers);
		if (providers.length > 0) {
			lines.push("providers:");
			for (const provider of providers) {
				lines.push(
					`  ${pickString(provider, "provider") ?? "?"} · ${pickNumber(provider, "requests") ?? 0} req · ${humanCost(pickNumber(provider, "cost")) ?? "$0"}`,
				);
			}
		}
		ctx.ui.noticeBlock(lines);
	},
};

/** Translate a range word (7d, 30d, today, week, month) into startDate/endDate. */
function costRangeParams(range: string): { startDate: string; endDate: string } | undefined {
	const DAY_MS = 24 * 60 * 60 * 1000;
	const iso = (ms: number) => new Date(ms).toISOString().slice(0, 10);
	const now = Date.now();
	const daysMatch = /^(\d{1,3})d$/.exec(range.toLowerCase());
	let days: number | undefined;
	if (daysMatch) days = Number(daysMatch[1]);
	else if (range === "today") days = 0;
	else if (range === "week") days = 7;
	else if (range === "month") days = 30;
	if (days === undefined) return undefined;
	return { startDate: iso(now - days * DAY_MS), endDate: iso(now) };
}

export const costCommand: SlashCommand = {
	name: "cost",
	summary: "spend breakdown",
	usage: "[range]",
	group: "diagnostics",
	methods: [METHOD.usageCost],
	async run(ctx, argv) {
		const range = argv[0];
		// The server only understands startDate/endDate (ISO dates); range
		// words are a client-side convenience translated here.
		const params = range ? costRangeParams(range) : undefined;
		if (range && !params) {
			ctx.ui.noticeBlock([`cost: unrecognized range "${range}" (try 7d, 30d, today, week, month)`]);
			return;
		}
		const result = await ctx.methods.usageCost(params);
		const lines = [`cost${range ? ` — ${range}` : ""}`];
		const span = `${pickString(result, "startDate") ?? "?"} → ${pickString(result, "endDate") ?? "?"}`;
		lines.push(`period: ${span}`);
		const total = pickNumber(result, "totalCost", "total", "cost", "summary.total");
		if (total !== undefined) lines.push(`total: ${humanCost(total)}`);
		const breakdown = result.breakdown;
		if (breakdown && typeof breakdown === "object" && !Array.isArray(breakdown)) {
			for (const [provider, cost] of Object.entries(breakdown as Record<string, unknown>)) {
				if (typeof cost === "number") lines.push(`  ${provider}: ${humanCost(cost)}`);
			}
		} else {
			const providers = asArray(result.providers ?? breakdown);
			for (const provider of providers) {
				lines.push(
					`  ${pickString(provider, "provider", "name") ?? "?"}: ${humanCost(pickNumber(provider, "cost", "total")) ?? "$0"}`,
				);
			}
		}
		ctx.ui.noticeBlock(lines);
	},
};

export const logsCommand: SlashCommand = {
	name: "logs",
	summary: "tail the daemon log",
	usage: "[count] [level]",
	group: "diagnostics",
	methods: [METHOD.logsTail],
	async run(ctx, argv) {
		const countArg = argv.find((arg) => /^\d+$/.test(arg));
		const level = argv.find((arg) => !/^\d+$/.test(arg));
		const limit = countArg ? Math.min(Number.parseInt(countArg, 10), 200) : 20;
		const result = await ctx.methods.logsTail({ limit, level });
		const logs = asArray((result as { logs?: unknown })?.logs);
		if (logs.length === 0) {
			ctx.ui.notice("no log entries");
			return;
		}
		const lines = [`logs — last ${logs.length}${level ? ` at ${level}` : ""}`];
		for (const entry of logs) {
			const when = pickNumber(entry, "timestampMs", "timestamp");
			const stamp = when ? new Date(when).toISOString().slice(11, 19) : undefined;
			lines.push(
				[stamp, pickString(entry, "level"), pickString(entry, "message")].filter(Boolean).join(" "),
			);
		}
		ctx.ui.noticeBlock(lines);
	},
};
