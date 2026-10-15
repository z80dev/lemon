import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import { card, EMPTY_NODE, node, span, text } from "@oh-my-pi/pi-tui/native/describe";
import type { NativeNode } from "@oh-my-pi/pi-tui/native/node";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth } from "@oh-my-pi/pi-tui/utils";
import {
	isTaskActive,
	type TaskStatus,
	type TaskTreeRow,
	taskElapsedMs,
} from "../../store/task-store.ts";
import { taskDisplayText } from "../task-progress.ts";
import { getTheme } from "../theme/theme.ts";

/** The `agent` node's props, via pi-tui's node type (pi-wire is not a direct dependency). */
type AgentProps = NonNullable<Extract<NativeNode, { k: "agent" }>["p"]>;

const AGENT_STATUS: Record<TaskStatus, AgentProps["status"]> = {
	queued: "pending",
	running: "running",
	cancelling: "running",
	completed: "done",
	error: "failed",
	aborted: "aborted",
	unknown: "idle",
};

/** A bounded live region; selection makes every remaining child reachable. */
export const TASK_TREE_WINDOW = 4;

export interface TaskTreeOptions {
	requestRender: () => void;
	onBlur: () => void;
	now?: () => number;
}

/** Mount outside the transcript: keyed child updates must never enter scrollback. */
export class TaskTreeComponent implements Component {
	focused = false;
	readonly #options: TaskTreeOptions;
	#rows: readonly TaskTreeRow[] = [];
	#selected = 0;
	#visible = false;
	#native: { rows: readonly TaskTreeRow[]; node: NativeNode } | undefined;

	constructor(options: TaskTreeOptions) {
		this.#options = options;
	}

	get visible(): boolean {
		return this.#visible;
	}

	get selected(): TaskTreeRow | undefined {
		return this.#rows[this.#selected];
	}

	setVisible(visible: boolean): void {
		this.#visible = visible;
	}

	update(rows: readonly TaskTreeRow[]): void {
		const selectedId = this.selected?.task.taskId;
		this.#rows = rows;
		const index = selectedId ? rows.findIndex((row) => row.task.taskId === selectedId) : -1;
		this.#selected = index >= 0 ? index : Math.max(0, Math.min(this.#selected, rows.length - 1));
	}

	handleInput(data: string): void {
		if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) {
			this.#options.onBlur();
			return;
		}
		let delta = 0;
		if (matchesKey(data, "up") || matchesKey(data, "ctrl+p")) delta = -1;
		if (matchesKey(data, "down") || matchesKey(data, "ctrl+n")) delta = 1;
		if (matchesKey(data, "pageUp")) delta = -TASK_TREE_WINDOW;
		if (matchesKey(data, "pageDown")) delta = TASK_TREE_WINDOW;
		const next = Math.max(0, Math.min(this.#rows.length - 1, this.#selected + delta));
		if (next === this.#selected) return;
		this.#selected = next;
		this.#options.requestRender();
	}

	invalidate(): void {
		// No cached rows: theme, focus and elapsed time are read at render time.
	}

	/**
	 * omp's task card (`omp.tool.task`) holding one `agent` node per child
	 * (`omp.task.agent`) at its lineage depth: status, role, description,
	 * terminal-clocked age while running (frozen time once finished) and the
	 * current activity as its body. The terminal scrolls the whole tree, so
	 * the row renderer's window does not apply.
	 */
	describe(): NativeNode {
		if (!this.#visible) return EMPTY_NODE;
		if (this.#native?.rows === this.#rows) return this.#native.node;
		const rows = this.#rows;
		const active = rows.filter((row) => isTaskActive(row.task.status)).length;
		const now = this.#options.now?.() ?? Date.now();
		const agents: NativeNode[] = rows.map(({ task, depth }) => {
			const id = taskDisplayText(task.taskId);
			const ms = taskElapsedMs(task, now);
			const props: AgentProps = {
				name: id,
				status: AGENT_STATUS[task.status],
				role: "omp.task.agent",
				...(task.agent ? { agent: task.agent } : {}),
				...(task.description && task.description !== id ? { task: task.description } : {}),
				...(task.status !== "unknown" ? { stats: task.finishedAt !== undefined ? { took: ms } : { age: ms } } : {}),
				...(task.status === "unknown"
					? { badges: [{ text: "outcome unknown", tone: "warning" as const }] }
					: task.status === "cancelling"
						? { badges: [{ text: "cancelling", tone: "warning" as const }] }
						: {}),
				...(depth > 0 ? { depth } : {}),
				...(task.progress ? { collapsible: true, collapsed: false } : {}),
			};
			return node(
				"agent",
				props,
				task.progress ? [text([span(task.progress, "muted")], { wrap: "word" })] : [],
				task.taskId,
			);
		});
		const described = card(
			{
				role: "omp.tool.task",
				head: [
					span("Tasks", "strong"),
					span(` · ${rows.length} children · ${active} active`, "muted"),
				],
				status: active > 0 ? "running" : "done",
			},
			agents.length > 0
				? agents
				: [text([span("No child task updates in this session.", "dim")], { key: "empty" })],
		);
		this.#native = { rows, node: described };
		return described;
	}

	render(width: number): readonly string[] {
		if (!this.#visible || width <= 0) return EMPTY;
		const theme = getTheme();
		const clamp = (text: string) => truncateToWidth(text, width);
		const active = this.#rows.filter((row) => isTaskActive(row.task.status)).length;
		const hint = this.focused ? " · ↑↓ browse · esc done" : "";
		const lines = [
			theme.fg("accent", clamp(`tasks · ${this.#rows.length} children · ${active} active${hint}`)),
		];
		if (this.#rows.length === 0) {
			lines.push(theme.fg("dim", clamp("No child task updates in this session.")));
			return lines;
		}
		const now = this.#options.now?.() ?? Date.now();
		const start = Math.max(
			0,
			Math.min(this.#selected - TASK_TREE_WINDOW + 1, this.#rows.length - TASK_TREE_WINDOW),
		);
		const end = Math.min(start + TASK_TREE_WINDOW, this.#rows.length);
		for (let index = start; index < end; index++) {
			const { task, depth } = this.#rows[index]!;
			const selected = this.focused && index === this.#selected;
			// Bound indentation even if the wire contains a very deep hierarchy.
			const indent = "  ".repeat(Math.min(depth, 5));
			const branch = depth > 0 ? "└─ " : "";
			const marker = selected ? theme.cursor : " ";
			const seconds = Math.floor(taskElapsedMs(task, now) / 1000);
			const elapsed = task.status === "unknown" ? "" : seconds < 60 ? `${seconds}s` : `${Math.floor(seconds / 60)}m${seconds % 60}s`;
			const agent = task.agent ? ` @${task.agent}` : "";
			const id = taskDisplayText(task.taskId);
			const label = task.description || id;
			const identity = label !== id ? ` · ${id}` : "";
			const text = `${marker} ${indent}${branch}${task.status} ${elapsed} · ${label}${agent}${identity}`;
			const color =
				task.status === "error"
					? "error"
					: task.status === "aborted"
						? "warning"
						: task.status === "completed"
							? "success"
							: "text";
			lines.push(theme.fg(selected ? "accent" : color, clamp(text)));
			if (task.progress) lines.push(theme.fg("muted", clamp(`    ${indent}${task.progress}`)));
		}
		const hidden = this.#rows.length - (end - start);
		if (hidden > 0) lines.push(theme.fg("dim", clamp(`  …${hidden} more · ↑↓ browse`)));
		return lines;
	}
}

const EMPTY: readonly string[] = Object.freeze([]);
