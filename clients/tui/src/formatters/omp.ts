/**
 * Formatter for the Lemon agent's `omp` tool, which drives external omp
 * (oh-my-pi) delegate processes: start, status, list, wait, send, cancel,
 * close, resume and discover.
 *
 * Results carry structured details — `{action, session: session_wire}`,
 * `{action: "list", sessions: [session_wire]}` or
 * `{action: "discover", sessions: [discovered_wire]}` — and `wait` streams the
 * same shape as partial updates. Every string inside is omp output and
 * untrusted: it is reduced to plain, control-free text before display.
 *
 * The status helpers are shared with the `/omp` panel so both describe a
 * session in the same words.
 */

import {
	isOmpSessionBusy,
	type OmpDiscoveredSession,
	type OmpSession,
	type OmpSessionStatus,
	type OmpTodo,
	parseOmpDiscoveredList,
	parseOmpSession,
	parseOmpSessions,
} from "../protocol/omp.ts";
import { extractText, safeLine, safeText, truncateLines } from "./base.js";
import type { FormattedOutput, ToolFormatter } from "./types.js";

/** Preview of a prompt or message in a one-line summary. */
const PREVIEW_MAX_LENGTH = 60;
/** Lines of the session's final (or latest) text a card shows before eliding. */
const RESULT_MAX_LINES = 6;
const DETAILS_MAX_LINES = 24;

export const OMP_STATUS_GLYPHS: Record<OmpSessionStatus, string> = {
	starting: "◌",
	running: "▶",
	idle: "○",
	closed: "■",
	failed: "✗",
	unknown: "?",
};

function str(value: unknown): string | undefined {
	return typeof value === "string" && value.length > 0 ? value : undefined;
}

function record(value: unknown): Record<string, unknown> {
	return value !== null && typeof value === "object" && !Array.isArray(value)
		? (value as Record<string, unknown>)
		: {};
}

/** `12.3k`, `1.2M`: a glance, not a report. */
export function compactCount(value: number): string {
	if (value < 1000) return String(Math.round(value));
	if (value < 1_000_000) return `${(value / 1000).toFixed(value < 10_000 ? 1 : 0)}k`;
	return `${(value / 1_000_000).toFixed(1)}M`;
}

/** `idle · completed`, `failed`, `running`. */
export function ompStatusText(session: OmpSession): string {
	return session.lastTurn && !isOmpSessionBusy(session)
		? `${session.status} · ${safeLine(session.lastTurn, 20)}`
		: session.status;
}

/** `3/5` closed todos, or undefined when omp reported none. */
export function ompTodoProgress(todos: readonly OmpTodo[]): string | undefined {
	if (todos.length === 0) return undefined;
	const closed = todos.filter(
		(todo) => todo.status === "completed" || todo.status === "done" || todo.status === "abandoned",
	).length;
	return `${closed}/${todos.length}`;
}

/** `41.2k tok · $0.0018 · ctx 0.9%`, or undefined before any usage was reported. */
export function ompUsageText(session: OmpSession): string | undefined {
	const parts: string[] = [];
	const tokens = session.usage?.totalTokens;
	if (tokens != null && tokens >= 0) parts.push(`${compactCount(tokens)} tok`);
	const cost = session.usage?.cost;
	if (cost != null && cost >= 0) parts.push(`$${cost.toFixed(cost < 0.01 ? 4 : 2)}`);
	if (session.contextPercent != null && session.contextPercent >= 0) {
		parts.push(`ctx ${session.contextPercent.toFixed(session.contextPercent < 10 ? 1 : 0)}%`);
	}
	return parts.length > 0 ? parts.join(" · ") : undefined;
}

/** A session's display name: its (sanitized) title, else its invocation id. */
export function ompSessionLabel(session: OmpSession, maxLength = PREVIEW_MAX_LENGTH): string {
	return safeLine(session.title, maxLength) || session.id;
}

/** Bounded plain-text facts shared by tool cards and semantic session nodes. */
export function ompExtraLines(value: unknown): string[] {
	const raw = record(value);
	const lines: string[] = [];
	if (Array.isArray(raw.pendingApprovals)) {
		for (const approval of raw.pendingApprovals.slice(0, 4)) {
			lines.push(`waiting for approval: ${safeLine(str(record(approval).tool) ?? "tool", 60)}`);
		}
	}
	const tree = record(raw.worktree);
	if (Object.keys(tree).length) {
		lines.push(
			`worktree: ${safeLine(str(tree.branch) ?? str(tree.path) ?? "unknown", 100)}${tree.kept === true ? " · kept" : ""}${tree.dirty === true ? " · dirty" : ""}`,
		);
	}
	return lines;
}

function sessionLines(session: OmpSession, details: Record<string, unknown>): string[] {
	const lines: string[] = [...ompExtraLines(details.session), `status: ${ompStatusText(session)}`];
	const identity = session.ompSessionId
		? `${session.id} · omp ${safeLine(session.ompSessionId, 40)}`
		: session.id;
	lines.push(`id: ${identity}`);
	if (session.model) lines.push(`model: ${safeLine(session.model, 100)}`);
	if (session.thinking) lines.push(`thinking: ${safeLine(session.thinking, 30)}`);
	if (session.activity) lines.push(`activity: ${safeLine(session.activity)}`);
	for (const tool of session.activeTools) {
		const intent = tool.intent ? ` — ${safeLine(tool.intent, 120)}` : "";
		lines.push(`▶ ${safeLine(tool.name, 40)}${intent}`);
	}
	const todos = ompTodoProgress(session.todos);
	if (todos) lines.push(`todos: ${todos}`);
	const usage = ompUsageText(session);
	if (usage) lines.push(`usage: ${usage}`);
	const delivery = str(details.delivery);
	if (delivery) lines.push(`delivery: ${safeLine(delivery, 20)}`);
	if (session.declinedPrompts > 0) {
		lines.push(`declined prompts: ${session.declinedPrompts}`);
	}
	for (const child of (Array.isArray(record(details.session).subagents)
		? (record(details.session).subagents as unknown[])
		: []
	).slice(0, 4)) {
		const agent = record(child);
		lines.push(
			`↳ ${safeLine(str(agent.id) ?? "subagent", 40)} · ${safeLine(str(agent.status) ?? "unknown", 20)}${agent.activity ? ` · ${safeLine(str(agent.activity) ?? "", 100)}` : ""}`,
		);
	}
	if (session.error) lines.push(`error: ${safeLine(session.error)}`);
	const text = session.result ?? session.lastText;
	if (text) {
		lines.push("", session.result ? "result:" : "latest:");
		lines.push(...truncateLines(safeText(text).trim().split("\n"), RESULT_MAX_LINES));
	}
	return lines;
}

function listLine(session: OmpSession): string {
	const activity = session.activity ? ` · ${safeLine(session.activity, 80)}` : "";
	return `${OMP_STATUS_GLYPHS[session.status]} ${ompSessionLabel(session)} (${session.id}) · ${ompStatusText(session)}${activity}`;
}

function discoveredLine(row: OmpDiscoveredSession): string {
	const marks = [
		safeLine(row.lastStatus, 20),
		row.liveId ? `live ${row.liveId}` : undefined,
		row.activeElsewhere ? "active elsewhere" : undefined,
	].filter(Boolean);
	const title = safeLine(row.title, PREVIEW_MAX_LENGTH) || "(untitled)";
	return `${safeLine(row.ompSessionId, 13)} ${title} · ${marks.join(" · ")}`;
}

/** A result or a streamed `wait` update. */
function formatOmpResult(result: unknown, args: Record<string, unknown> = {}): FormattedOutput {
	const obj = record(result);
	const details = record(obj.details);
	const action = safeLine(str(details.action) ?? str(args.action) ?? "omp", 20);
	const isError = obj.is_error === true;
	const text = safeText(extractText(result)).trim();

	if ((action === "start_many" || action === "wait") && Array.isArray(details.sessions)) {
		const sessions = parseOmpSessions(details.sessions);
		const lines = sessions
			.slice(0, 8)
			.map((worker) =>
				[
					safeLine(worker.id, 40),
					ompStatusText(worker),
					safeLine(worker.result ?? worker.activity ?? worker.lastText ?? worker.error ?? "", 100),
					ompTodoProgress(worker.todos) ? `todos ${ompTodoProgress(worker.todos)}` : undefined,
				]
					.filter(Boolean)
					.join(" · "),
			);
		const usage = record(details.usage);
		const total =
			typeof usage.totalTokens === "number" && Number.isFinite(usage.totalTokens)
				? compactCount(usage.totalTokens)
				: "?";
		const cost =
			typeof usage.cost === "number" && Number.isFinite(usage.cost)
				? `$${usage.cost.toFixed(4)}`
				: "?";
		lines.push(`combined: ${total} tok · ${cost}`);
		if (details.reason) lines.push(`wait: ${safeLine(str(details.reason) ?? "", 30)}`);
		for (const value of (Array.isArray(details.errors) ? details.errors : []).slice(0, 8)) {
			const error = record(value);
			lines.push(
				`task ${typeof error.task === "number" ? error.task + 1 : "?"}: ${safeLine(str(error.error) ?? "error", 50)} · ${safeLine(str(error.message) ?? "", 160)}`,
			);
		}
		return {
			summary: `${action} · ${sessions.length} workers`,
			details: truncateLines(lines, DETAILS_MAX_LINES),
			isError,
		};
	}
	if (action === "models" && Array.isArray(details.models)) {
		const lines = details.models.slice(0, DETAILS_MAX_LINES - 1).map((value) => {
			const model = record(value);
			const input =
				typeof model.costInput === "number" && Number.isFinite(model.costInput)
					? `$${model.costInput}`
					: "?";
			const output =
				typeof model.costOutput === "number" && Number.isFinite(model.costOutput)
					? `$${model.costOutput}`
					: "?";
			return `${safeLine(str(model.selector) ?? "unknown", 100)} · ctx ${typeof model.contextWindow === "number" ? compactCount(model.contextWindow) : "?"} · ${model.free === true ? "FREE" : `${input}/${output} per Mtok`}`;
		});
		lines.push("Catalog prices may change; free routes may be unavailable.");
		return { summary: `models · ${details.models.length} models`, details: lines, isError };
	}
	if (action === "subagent" && Array.isArray(record(details.transcript).messages)) {
		const messages = record(details.transcript).messages as unknown[];
		const lines = messages.slice(-6).flatMap((value) => {
			const message = record(value);
			return [
				`[${safeLine(str(message.role) ?? "unknown", 20)}${message.toolName ? ` ${safeLine(str(message.toolName) ?? "", 40)}` : ""}]`,
				...truncateLines(safeText(str(message.text) ?? "").split("\n"), 3),
			];
		});
		return {
			summary: `subagent · ${safeLine(str(details.subagentId) ?? "", 60)}`,
			details: truncateLines(lines, DETAILS_MAX_LINES),
			isError,
		};
	}
	if (action === "list" && Array.isArray(details.sessions)) {
		const sessions = parseOmpSessions(details.sessions);
		const busy = sessions.filter(isOmpSessionBusy).length;
		return {
			summary: `list · ${sessions.length} session${sessions.length === 1 ? "" : "s"}${busy > 0 ? ` (${busy} running)` : ""}`,
			details: truncateLines(sessions.map(listLine), DETAILS_MAX_LINES),
			isError,
		};
	}
	if (action === "discover" && Array.isArray(details.sessions)) {
		const rows = parseOmpDiscoveredList(details.sessions);
		return {
			summary: `discover · ${rows.length} session${rows.length === 1 ? "" : "s"}`,
			details: truncateLines(
				rows.slice(0, DETAILS_MAX_LINES).map((row, index) => {
					const raw = record((details.sessions as unknown[])[index]);
					return `${discoveredLine(row)}${raw.source ? ` · ${safeLine(str(raw.source) ?? "", 20)}` : ""}${raw.interrupted === true ? " · interrupted" : ""}${record(raw.worktree).branch ? ` · ${safeLine(str(record(raw.worktree).branch) ?? "", 60)}` : ""}`;
				}),
				DETAILS_MAX_LINES,
			),
			isError,
		};
	}
	const session = parseOmpSession(details.session);
	if (session) {
		const todos = ompTodoProgress(session.todos);
		return {
			summary: [
				`${action} · ${ompSessionLabel(session)}`,
				ompStatusText(session),
				todos ? `todos ${todos}` : undefined,
				ompExtraLines(details.session).find((line) => line.startsWith("waiting for approval:")),
			]
				.filter(Boolean)
				.join(" · "),
			details: truncateLines(sessionLines(session, details), DETAILS_MAX_LINES),
			isError,
		};
	}
	const lines = text ? text.split("\n") : [];
	return {
		summary: lines[0] ? safeLine(lines[0]) : action,
		details: truncateLines(lines, DETAILS_MAX_LINES),
		isError,
	};
}

export const ompFormatter: ToolFormatter = {
	tools: ["omp"],

	formatArgs(args: Record<string, unknown>): FormattedOutput {
		const action = safeLine(str(args.action) ?? "omp", 20);
		const target = str(args.id) ?? str(args.omp_session_id);
		const body = str(args.prompt) ?? str(args.message);
		const preview = body ? safeLine(body, PREVIEW_MAX_LENGTH) : undefined;
		const head =
			action === "discover" && str(args.cwd)
				? `${action} ${safeLine(str(args.cwd) ?? "", PREVIEW_MAX_LENGTH)}`
				: target
					? `${action} ${safeLine(target, 40)}`
					: action;

		const details = [`action: ${action}`];
		for (const key of ["id", "omp_session_id", "cwd", "model", "thinking", "mode"]) {
			const value = str(args[key]);
			if (value) details.push(`${key}: ${safeLine(value)}`);
		}
		if (typeof args.timeout_seconds === "number") {
			details.push(`timeout_seconds: ${args.timeout_seconds}`);
		}
		if (Array.isArray(args.tasks)) details.push(`workers: ${args.tasks.length}`);
		if (Array.isArray(args.ids))
			details.push(
				`ids: ${args.ids
					.slice(0, 8)
					.map((id) => safeLine(str(id) ?? "?", 40))
					.join(", ")}`,
			);
		if (args.continue === true) details.push("continue: true");
		if (args.wait === true) details.push("wait: true");
		if (body) details.push("", ...truncateLines(safeText(body).split("\n"), 10));
		return {
			summary: preview ? `${head}: ${preview}` : head,
			details: truncateLines(details, DETAILS_MAX_LINES),
		};
	},

	formatResult(result: unknown, args?: Record<string, unknown>): FormattedOutput {
		return formatOmpResult(result, args);
	},

	formatPartial(partial: unknown, args?: Record<string, unknown>): FormattedOutput {
		return formatOmpResult(partial, args);
	},
};
