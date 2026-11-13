/**
 * Row projection for the agent hub: the task tree's rows, flattened to what one
 * hub table line needs. Pure and clock-injected so the same rows render the same
 * way in tests, the table and the transcript header.
 */

import {
	isTaskActive,
	type TaskStatus,
	type TaskTreeRow,
	taskElapsedMs,
} from "../store/task-store.ts";
import { taskDisplayText } from "./task-progress.ts";

export interface AgentHubRow {
	taskId: string;
	/** Description, else the task id: always something a person can read. */
	label: string;
	agent?: string;
	status: TaskStatus;
	/** Lineage depth in the parent's task tree; 0 for direct children. */
	depth: number;
	/** Still queued, running or being cancelled. */
	active: boolean;
	/** Observed (not server-reported) age, frozen once the child finished; absent when the outcome is unknown. */
	elapsedMs?: number;
	progress?: string;
	/** The child's session; its history is the transcript. Absent until the launch receipt names it. */
	sessionId?: string;
	runId?: string;
}

export interface AgentHubSummary {
	total: number;
	active: number;
	completed: number;
	failed: number;
}

/** Tree order is kept: a child always follows its parent. */
export function projectAgentHubRows(rows: readonly TaskTreeRow[], now: number): AgentHubRow[] {
	return rows.map(({ task, depth }) => {
		const id = taskDisplayText(task.taskId);
		const description = task.description ? taskDisplayText(task.description) : "";
		return {
			taskId: task.taskId,
			label: description || id,
			...(task.agent ? { agent: taskDisplayText(task.agent) } : {}),
			status: task.status,
			depth,
			active: isTaskActive(task.status),
			...(task.status !== "unknown" ? { elapsedMs: taskElapsedMs(task, now) } : {}),
			...(task.progress ? { progress: task.progress } : {}),
			...(task.sessionId ? { sessionId: task.sessionId } : {}),
			...(task.runId ? { runId: task.runId } : {}),
		};
	});
}

export function summarizeAgentHubRows(rows: readonly AgentHubRow[]): AgentHubSummary {
	const summary: AgentHubSummary = { total: rows.length, active: 0, completed: 0, failed: 0 };
	for (const row of rows) {
		if (row.active) summary.active += 1;
		else if (row.status === "completed") summary.completed += 1;
		else if (row.status === "error" || row.status === "aborted") summary.failed += 1;
	}
	return summary;
}

/** `42s`, `3m05s`, `1h02m`; empty for an unknown duration. */
export function formatElapsed(ms: number | undefined): string {
	if (ms === undefined) return "";
	const seconds = Math.floor(Math.max(0, ms) / 1000);
	if (seconds < 60) return `${seconds}s`;
	const minutes = Math.floor(seconds / 60);
	if (minutes < 60) return `${minutes}m${String(seconds % 60).padStart(2, "0")}s`;
	return `${Math.floor(minutes / 60)}h${String(minutes % 60).padStart(2, "0")}m`;
}
