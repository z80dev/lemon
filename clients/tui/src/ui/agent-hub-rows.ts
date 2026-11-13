/**
 * Row logic for the Agent Hub, kept pure and clock-injected so the roster, the
 * transcript header and the native card read the same facts the same way:
 * which rows are shown (filter, tree or flat order), how an agent is named, its
 * clock, whether it can be messaged, and the usage it reported.
 *
 * Every string taken from a task is child output; it leaves here only through
 * `safeLine`.
 */

import { safeLine } from "../formatters/base.ts";
import { compactCount } from "../formatters/omp.ts";
import {
	isTaskActive,
	isTaskTerminal,
	type TaskRecord,
	type TaskStatus,
	type TaskTreeRow,
} from "../store/task-store.ts";
import { formatElapsed } from "./components/omp-panel.ts";

export type HubLayout = "tree" | "flat";

/** The hub's status vocabulary: the daemon's `failed`/`cancelled` for terminal errors. */
export const STATUS_LABEL: Record<TaskStatus, string> = {
	queued: "queued",
	running: "running",
	cancelling: "cancelling",
	idle: "idle",
	parked: "parked",
	completed: "completed",
	error: "failed",
	aborted: "cancelled",
	unknown: "unknown",
};

/** Flat-roster order: what needs attention first. */
const OPERATIONAL_RANK: Record<TaskStatus, number> = {
	running: 0,
	cancelling: 0,
	queued: 1,
	idle: 2,
	parked: 3,
	unknown: 4,
	error: 5,
	aborted: 6,
	completed: 7,
};

/**
 * The rows the roster shows. A filter matches id, name, persona or assignment;
 * the tree keeps lineage order (a child always follows its parent), the flat
 * layout ranks by what needs attention, then by most recent update.
 */
export function shownHubRows(
	rows: readonly TaskTreeRow[],
	filter: string,
	layout: HubLayout,
): readonly TaskTreeRow[] {
	const query = filter.trim().toLowerCase();
	let shown = rows;
	if (query) {
		shown = shown.filter(({ task }) =>
			[task.taskId, task.name, task.agent, task.description].some((field) =>
				field?.toLowerCase().includes(query),
			),
		);
	}
	if (layout === "flat") {
		shown = [...shown]
			.sort(
				(a, b) =>
					OPERATIONAL_RANK[a.task.status] - OPERATIONAL_RANK[b.task.status] ||
					b.task.updatedAt - a.task.updatedAt,
			)
			.map(({ task }) => ({ task, depth: 0 }));
	}
	return shown;
}

/** Name, else assignment, else the opaque id: always something a person can read. */
export function hubLabel(task: TaskRecord): string {
	return safeLine(task.name ?? task.description ?? task.taskId, 80) || task.taskId;
}

/** `Researcher @scout · 3f2a…`: label, persona, and the opaque ID when it differs. */
export function hubIdentity(task: TaskRecord): string {
	const id = safeLine(task.taskId, 40);
	const shown = hubLabel(task);
	const agent = task.agent ? ` @${safeLine(task.agent, 40)}` : "";
	return `${shown}${agent}${shown !== id ? ` · ${id}` : ""}`;
}

/**
 * Running/queued: time since start; idle/parked: time since the last turn
 * ended; finished: how long it took. Unknown outcomes have no clock.
 */
export function hubClockMs(task: TaskRecord, now: number): number | undefined {
	if (task.status === "unknown") return undefined;
	if (task.status === "idle" || task.status === "parked") {
		return task.finishedAt === undefined ? undefined : Math.max(0, now - task.finishedAt);
	}
	return Math.max(0, (task.finishedAt ?? now) - task.observedAt);
}

export function hubClockText(task: TaskRecord, now: number): string {
	const ms = hubClockMs(task, now);
	return ms === undefined ? "" : formatElapsed(ms);
}

/** The daemon's word wins; streamed events alone allow live, idle and parked agents. */
export function canMessage(task: TaskRecord): boolean {
	if (task.messaging !== undefined) return task.messaging;
	return isTaskActive(task.status) || task.status === "idle" || task.status === "parked";
}

export function sendVerb(task: TaskRecord): string {
	return task.status === "idle" ? "follow up" : task.status === "parked" ? "revive" : "steer";
}

/** One line under the roster for the selected agent. */
export function hubInspector(task: TaskRecord): string {
	return [
		`task ${safeLine(task.taskId, 40)}`,
		task.parentTaskId ? `parent ${safeLine(task.parentTaskId, 40)}` : undefined,
		task.sessionId ? `session ${safeLine(task.sessionId, 40)}` : undefined,
		task.contextPercent !== undefined ? `ctx ${task.contextPercent.toFixed(0)}%` : undefined,
		task.description && task.name ? safeLine(task.description, 160) : undefined,
	]
		.filter(Boolean)
		.join(" · ");
}

export function totalUsage(tasks: readonly TaskRecord[]): TaskRecord["usage"] {
	const total: NonNullable<TaskRecord["usage"]> = {};
	for (const task of tasks) {
		for (const field of ["tokens", "costUsd", "requests"] as const) {
			const value = task.usage?.[field];
			if (value !== undefined) total[field] = (total[field] ?? 0) + value;
		}
	}
	return total;
}

/** `12.4k tok $0.12 31 req`; unknown counters are omitted, never shown as zero. */
export function usageText(usage: TaskRecord["usage"]): string | undefined {
	if (!usage) return undefined;
	const parts: string[] = [];
	if (usage.tokens !== undefined) parts.push(`${compactCount(usage.tokens)} tok`);
	if (usage.costUsd !== undefined) {
		parts.push(`$${usage.costUsd.toFixed(usage.costUsd < 0.01 ? 4 : 2)}`);
	}
	if (usage.requests !== undefined) parts.push(`${usage.requests} req`);
	return parts.length > 0 ? parts.join(" ") : undefined;
}

/** `2 running · 1 idle · 3 done · 12.4k tok`, in a fixed order; empty sessions say so. */
export function hubHeadline(tasks: readonly TaskRecord[]): string {
	if (tasks.length === 0) return "no subagents in this session";
	const counts = new Map<string, number>();
	for (const task of tasks) {
		const group = isTaskTerminal(task.status) ? "done" : STATUS_LABEL[task.status];
		counts.set(group, (counts.get(group) ?? 0) + 1);
	}
	const order = ["running", "cancelling", "queued", "idle", "parked", "unknown", "done"];
	const parts = order.filter((key) => counts.has(key)).map((key) => `${counts.get(key)} ${key}`);
	const usage = usageText(totalUsage(tasks));
	if (usage) parts.push(usage);
	return parts.join(" · ");
}
