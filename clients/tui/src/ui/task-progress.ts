import { extractText, safeLine } from "../formatters/base.ts";
import type { AgentToolUseEvent } from "../protocol/types.ts";
import type { TaskStatus, TaskUpdate } from "../store/task-store.ts";

/** The panel keeps the latest bounded summary, not an additional output log. */
export const TASK_PROGRESS_LIMIT = 512;

/**
 * Read native progress, launch receipts and task join/get receipts. Tool and
 * parent run completion alone never supplies a child status.
 */
export function taskUpdatesFromEvent(event: AgentToolUseEvent): TaskUpdate[] {
	const detail = event.action?.detail;
	if (detail?.name !== "task" && detail?.name !== "agent") return [];
	const partial = record(detail.partial_result);
	const sources: Array<{ details: Record<string, unknown>; text?: string }> = [];
	// Completed actions may retain a previous partial_result; the receipt must
	// win over that stale snapshot, including when a join contains many tasks.
	const partialDetails = record(partial?.details);
	if (partialDetails) sources.push({ details: partialDetails, text: extractText(partial) });
	const receiptDetails = record(detail.details);
	if (receiptDetails) {
		sources.push({
			details: receiptDetails,
			text: extractText(detail.result_full ?? detail.result),
		});
	}
	const updates: TaskUpdate[] = [];
	for (const source of sources) {
		const entries: Array<{ details: Record<string, unknown>; text?: string }> = [];
		// Blocking batch launches may contain both launches and final tasks.
		for (const field of ["launches", "tasks"]) {
			const values = source.details[field];
			if (!Array.isArray(values)) continue;
			for (const value of values) {
				const details = record(value);
				if (details) entries.push({ details });
			}
		}
		entries.push(source);
		for (const { details, text } of entries) {
			if (typeof details.task_id !== "string" || details.task_id.length === 0) continue;
			const update: TaskUpdate = { taskId: details.task_id };
			for (const [wire, field] of [
				["run_id", "runId"],
				["session_id", "sessionId"],
				["parent_run_id", "parentRunId"],
				["parent_session_id", "parentSessionId"],
			] as const) {
				const value = details[wire];
				if (typeof value === "string" && value.length > 0) update[field] = value;
			}
			if (event.action.id) update.launchActionId = event.action.id;
			if (typeof details.description === "string")
				update.description = taskDisplayText(details.description);
			if (typeof details.agent === "string") update.agent = taskDisplayText(details.agent);
			const status = childStatus(details.status);
			if (status) update.status = status;
			const current = record(details.current_action);
			const terminal = status === "completed" || status === "error" || status === "aborted";
			const result =
				typeof details.error === "string"
					? details.error
					: typeof details.output === "string"
						? details.output
						: text;
			const progress = !terminal && typeof current?.title === "string" ? current.title : result;
			if (typeof progress === "string" && progress.trim()) {
				update.progress = taskDisplayText(progress, true);
			}
			updates.push(update);
		}
	}
	return updates;
}

/** Display-only text: opaque keys remain untouched in the store. */
export function taskDisplayText(text: string, latest = false): string {
	const plain = safeLine(text, Number.POSITIVE_INFINITY);
	if (plain.length <= TASK_PROGRESS_LIMIT) return plain;
	return latest
		? `…${plain.slice(-(TASK_PROGRESS_LIMIT - 1))}`
		: `${plain.slice(0, TASK_PROGRESS_LIMIT - 1)}…`;
}

function childStatus(value: unknown): TaskStatus | undefined {
	switch (value) {
		case "pending":
		case "queued":
			return "queued";
		case "running":
		case "cancelling":
		case "completed":
		case "error":
		case "aborted":
			return value;
		case "cancelled":
		case "canceled":
			return "aborted";
		default:
			return undefined;
	}
}

/** Child progress is independent of the parent tool's already-completed launch receipt. */
export function taskProgressEvent(event: AgentToolUseEvent): AgentToolUseEvent | undefined {
	const detail = event.action?.detail;
	if (event.phase !== "updated" || (detail?.name !== "task" && detail?.name !== "agent")) {
		return undefined;
	}
	const partial = record(detail.partial_result);
	const details = record(partial?.details);
	const taskId = details?.task_id;
	if (!details || typeof taskId !== "string" || taskId.length === 0) return undefined;
	const status = details.status;
	const failed = status === "error" || status === "aborted" || status === "cancelled";
	const completed = status === "completed" || failed;
	const description = typeof details.description === "string" ? details.description : taskId;
	return {
		...event,
		phase: completed ? "completed" : "updated",
		ok: completed ? !failed : undefined,
		action: {
			id: `${event.action.id ?? "task"}:child:${taskId}`,
			kind: "subagent",
			title: description,
			detail: {
				name: detail.name,
				args: { task_id: taskId },
				partial_result: partial,
				details,
				result: extractText(partial),
			},
		},
	};
}

function record(value: unknown): Record<string, unknown> | undefined {
	return value !== null && typeof value === "object" && !Array.isArray(value)
		? (value as Record<string, unknown>)
		: undefined;
}
