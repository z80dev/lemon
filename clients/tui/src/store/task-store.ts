import { Emitter } from "./events.ts";

export type TaskStatus =
	| "queued"
	| "running"
	| "cancelling"
	| "completed"
	| "error"
	| "aborted"
	| "unknown";

/** Only child-owned metadata: a launch receipt's lifecycle is not a child's. */
export interface TaskUpdate {
	taskId: string;
	runId?: string;
	sessionId?: string;
	parentRunId?: string;
	parentSessionId?: string;
	launchActionId?: string;
	description?: string;
	agent?: string;
	status?: TaskStatus;
	progress?: string;
}

export interface TaskRecord extends TaskUpdate {
	status: TaskStatus;
	/** Arrival time, not an invented server start time. */
	observedAt: number;
	updatedAt: number;
	finishedAt?: number;
}

export interface TaskTreeRow {
	task: TaskRecord;
	depth: number;
	parentTaskId?: string;
}

interface TaskStoreEvents {
	changed: { sessionKey: string };
}

export function isTaskTerminal(status: TaskStatus): boolean {
	return status === "completed" || status === "error" || status === "aborted";
}

export function isTaskActive(status: TaskStatus): boolean {
	return status === "queued" || status === "running" || status === "cancelling";
}

export function taskElapsedMs(task: TaskRecord, now: number): number {
	return Math.max(0, (task.finishedAt ?? now) - task.observedAt);
}

/** Tasks outlive their launching tool and run, but never their owning chat. */
export class TaskStore {
	readonly events = new Emitter<TaskStoreEvents>();
	readonly #sessions = new Map<string, Map<string, TaskRecord>>();

	items(sessionKey: string): readonly TaskRecord[] {
		const tasks = this.#sessions.get(sessionKey);
		return tasks ? [...tasks.values()] : EMPTY;
	}

	find(sessionKey: string, taskId: string): TaskRecord | undefined {
		return this.#sessions.get(sessionKey)?.get(taskId);
	}

	upsert(sessionKey: string, updates: readonly TaskUpdate[], now: number): void {
		if (!sessionKey || updates.length === 0) return;
		let tasks = this.#sessions.get(sessionKey);
		if (!tasks) {
			tasks = new Map();
			this.#sessions.set(sessionKey, tasks);
		}
		for (const update of updates) {
			const previous = tasks.get(update.taskId);
			const status = update.status ?? previous?.status ?? "unknown";
			// Launch receipts can arrive after real progress, and delayed progress
			// can arrive after a terminal result. Neither may rewind the child.
			const stale =
				previous &&
				((isTaskTerminal(previous.status) && !isTaskTerminal(update.status ?? "unknown")) ||
					(previous.status === "running" && status === "queued") ||
					(previous.status === "cancelling" && (status === "queued" || status === "running")));
			const next: TaskRecord = {
				...previous,
				...update,
				launchActionId: previous?.launchActionId ?? update.launchActionId,
				status: stale ? previous.status : status,
				progress: stale ? previous.progress : (update.progress ?? previous?.progress),
				observedAt: previous?.observedAt ?? now,
				updatedAt: stale ? previous.updatedAt : now,
				finishedAt: previous?.finishedAt ?? (isTaskTerminal(status) ? now : undefined),
			};
			tasks.set(update.taskId, next);
		}
		this.events.emit("changed", { sessionKey });
	}

	clear(sessionKey: string): void {
		if (this.#sessions.delete(sessionKey)) this.events.emit("changed", { sessionKey });
	}

	/** Opaque IDs are never split. Late parent metadata reparents on the next read. */
	tree(sessionKey: string): readonly TaskTreeRow[] {
		const tasks = this.items(sessionKey);
		const byRun = new Map<string, TaskRecord>();
		const bySession = new Map<string, TaskRecord>();
		for (const task of tasks) {
			if (task.runId) byRun.set(task.runId, task);
			if (task.sessionId) bySession.set(task.sessionId, task);
		}
		const children = new Map<string, TaskRecord[]>();
		const parents = new Map<string, string>();
		for (const task of tasks) {
			const parent =
				(task.parentRunId ? byRun.get(task.parentRunId) : undefined) ??
				(task.parentSessionId ? bySession.get(task.parentSessionId) : undefined);
			if (!parent || parent === task) continue;
			parents.set(task.taskId, parent.taskId);
			const siblings = children.get(parent.taskId) ?? [];
			siblings.push(task);
			children.set(parent.taskId, siblings);
		}
		const rows: TaskTreeRow[] = [];
		const seen = new Set<string>();
		const append = (root: TaskRecord) => {
			const stack: TaskTreeRow[] = [{ task: root, depth: 0 }];
			while (stack.length > 0) {
				const row = stack.pop()!;
				if (seen.has(row.task.taskId)) continue;
				seen.add(row.task.taskId);
				rows.push(row);
				const nested = children.get(row.task.taskId) ?? [];
				for (let index = nested.length - 1; index >= 0; index--) {
					stack.push({ task: nested[index]!, depth: row.depth + 1, parentTaskId: row.task.taskId });
				}
			}
		};
		for (const task of tasks) if (!parents.has(task.taskId)) append(task);
		// Malformed cycles must not hide children or recurse forever.
		for (const task of tasks) if (!seen.has(task.taskId)) append(task);
		return rows;
	}
}

const EMPTY: readonly TaskRecord[] = Object.freeze([]);
