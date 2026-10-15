/**
 * Formatter for the todo tool.
 *
 * The tool takes an `action` (read, write, progress, actionable). Read, write,
 * and actionable return a todo list; progress returns completion counts.
 * Todos render as checkbox lines keyed by status.
 */

import { extractText, truncateLines, truncateText } from "./base.js";
import type { FormattedOutput, ToolFormatter } from "./types.js";

/** Maximum lines of todos to show in details */
const TODOS_MAX_LINES = 20;

/** Maximum length for an error line in the summary */
const ERROR_SUMMARY_MAX_LENGTH = 80;

/** Checkbox glyph per todo status; unknown statuses render as pending */
const STATUS_CHECKBOX: Record<string, string> = {
	completed: "☑",
	in_progress: "◐",
	blocked: "⊘",
	abandoned: "☒",
	pending: "☐",
};

/**
 * Todo item as stored by the todo tool.
 */
interface TodoItem {
	id?: string;
	content: string;
	status: string;
	priority?: string;
	phase?: string;
	blocker?: string;
}

/**
 * Completion counts returned by `action: "progress"`.
 */
interface TodoProgress {
	total: number;
	completed: number;
	in_progress: number;
	blocked: number;
	abandoned: number;
	pending: number;
	percentage: number;
}

/**
 * Keeps the entries that have the todo shape, defaulting a missing status to
 * pending.
 *
 * @param value - Candidate todo list
 * @returns Valid todo items
 */
function parseTodoList(value: unknown[]): TodoItem[] {
	const todos: TodoItem[] = [];
	for (const entry of value) {
		if (!entry || typeof entry !== "object") {
			continue;
		}
		const item = entry as Record<string, unknown>;
		if (typeof item.content !== "string") {
			continue;
		}
		todos.push({
			id: typeof item.id === "string" ? item.id : undefined,
			content: item.content,
			status: typeof item.status === "string" ? item.status : "pending",
			priority: typeof item.priority === "string" ? item.priority : undefined,
			phase: typeof item.phase === "string" ? item.phase : undefined,
			blocker: typeof item.blocker === "string" ? item.blocker : undefined,
		});
	}
	return todos;
}

/**
 * Reads progress counts from an object, when it has them.
 *
 * @param value - Candidate progress object
 * @returns Progress counts, or undefined
 */
function parseProgress(value: Record<string, unknown>): TodoProgress | undefined {
	const total = value.total;
	const completed = value.completed;
	if (typeof total !== "number" || typeof completed !== "number") {
		return undefined;
	}
	const count = (key: string) => (typeof value[key] === "number" ? (value[key] as number) : 0);
	let percentage = count("percentage");
	if (typeof value.percentage !== "number" && total > 0) {
		percentage = Math.floor((completed * 100) / total);
	}
	return {
		total,
		completed,
		in_progress: count("in_progress"),
		blocked: count("blocked"),
		abandoned: count("abandoned"),
		pending: count("pending"),
		percentage,
	};
}

/**
 * Formats a todo item as a checkbox line.
 *
 * @param item - The todo item to format
 * @returns Formatted checkbox line
 */
function formatTodoLine(item: TodoItem): string {
	const checkbox = STATUS_CHECKBOX[item.status] ?? STATUS_CHECKBOX.pending;
	const priority = item.priority === "high" ? " (high)" : "";
	const phase = item.phase ? `[${item.phase}] ` : "";
	const blocker = item.status === "blocked" && item.blocker ? ` — blocked: ${item.blocker}` : "";
	return `${checkbox} ${phase}${item.content}${priority}${blocker}`;
}

/**
 * Summarizes a todo list by status counts.
 *
 * @param todos - The todo items
 * @returns Summary like "1 in progress, 2 pending, 3 done"
 */
function summarizeTodos(todos: TodoItem[]): string {
	if (todos.length === 0) {
		return "no todos";
	}

	const counts: Record<string, number> = {};
	for (const item of todos) {
		const status = item.status in STATUS_CHECKBOX ? item.status : "pending";
		counts[status] = (counts[status] ?? 0) + 1;
	}

	const parts: string[] = [];
	if (counts.in_progress) {
		parts.push(`${counts.in_progress} in progress`);
	}
	if (counts.pending) {
		parts.push(`${counts.pending} pending`);
	}
	if (counts.blocked) {
		parts.push(`${counts.blocked} blocked`);
	}
	if (counts.abandoned) {
		parts.push(`${counts.abandoned} abandoned`);
	}
	if (counts.completed) {
		parts.push(`${counts.completed} done`);
	}
	return parts.join(", ");
}

/**
 * Formats progress counts.
 *
 * @param progress - The progress counts
 * @returns Formatted output
 */
function formatProgress(progress: TodoProgress): FormattedOutput {
	const details: string[] = [];
	if (progress.in_progress > 0) {
		details.push(`in progress: ${progress.in_progress}`);
	}
	if (progress.pending > 0) {
		details.push(`pending: ${progress.pending}`);
	}
	if (progress.blocked > 0) {
		details.push(`blocked: ${progress.blocked}`);
	}
	if (progress.abandoned > 0) {
		details.push(`abandoned: ${progress.abandoned}`);
	}
	return {
		summary: `${progress.completed}/${progress.total} done (${progress.percentage}%)`,
		details,
	};
}

/**
 * Formatter for the todo tool.
 */
export const todoFormatter: ToolFormatter = {
	tools: ["todo"],

	formatArgs(args: Record<string, unknown>): FormattedOutput {
		const action = typeof args.action === "string" ? args.action : "";

		if (action !== "write") {
			return {
				summary: action || "todo",
				details: [],
			};
		}

		const todos = Array.isArray(args.todos) ? parseTodoList(args.todos) : [];
		return {
			summary: `write ${todos.length} item${todos.length === 1 ? "" : "s"}`,
			details: truncateLines(todos.map(formatTodoLine), TODOS_MAX_LINES),
		};
	},

	formatResult(result: unknown, _args?: Record<string, unknown>): FormattedOutput {
		const obj =
			result && typeof result === "object" ? (result as Record<string, unknown>) : undefined;
		const text = extractText(result);

		if (obj?.is_error === true) {
			const lines = text.split(/\r?\n/).filter((line) => line.trim().length > 0);
			return {
				summary: lines.length > 0 ? truncateText(lines[0], ERROR_SUMMARY_MAX_LENGTH) : "failed",
				details: truncateLines(lines, TODOS_MAX_LINES),
				isError: true,
			};
		}

		const details =
			obj?.details && typeof obj.details === "object"
				? (obj.details as Record<string, unknown>)
				: undefined;

		// Structured details: a todo list (read/write/actionable) or counts (progress).
		if (details) {
			if (Array.isArray(details.todos)) {
				const todos = parseTodoList(details.todos);
				return {
					summary: summarizeTodos(todos),
					details: truncateLines(todos.map(formatTodoLine), TODOS_MAX_LINES),
				};
			}
			const progress = parseProgress(details);
			if (progress) {
				return formatProgress(progress);
			}
		}

		// The result text is the same data as pretty-printed JSON.
		let parsed: unknown;
		try {
			parsed = JSON.parse(text);
		} catch {
			parsed = undefined;
		}

		if (Array.isArray(parsed)) {
			const todos = parseTodoList(parsed);
			return {
				summary: summarizeTodos(todos),
				details: truncateLines(todos.map(formatTodoLine), TODOS_MAX_LINES),
			};
		}
		if (parsed && typeof parsed === "object") {
			const progress = parseProgress(parsed as Record<string, unknown>);
			if (progress) {
				return formatProgress(progress);
			}
		}

		// Unparseable (e.g. a truncated preview): show the text as-is.
		const lines = text.split(/\r?\n/).filter((line) => line.trim().length > 0);
		return {
			summary: lines.length > 0 ? truncateText(lines[0], ERROR_SUMMARY_MAX_LENGTH) : "no todos",
			details: truncateLines(lines, TODOS_MAX_LINES),
		};
	},
};

export default todoFormatter;
