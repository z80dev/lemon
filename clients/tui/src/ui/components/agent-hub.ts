/**
 * The Agent Hub (Alt+A, `/hub`): the focused session's task subagents, nested
 * children included. Mounted in the dock outside the transcript, so live
 * updates never enter scrollback.
 *
 *   roster      status, name/persona, model, clock, activity and usage per
 *               agent; `t` toggles parent/child tree and the operational flat
 *               order, `/` filters, Enter opens the transcript, `x` cancels
 *               (pressed twice), `r` refreshes, Escape clears the filter first
 *               and then closes the hub
 *   transcript  the agent's bounded visible transcript with an input line:
 *               typing steers a running agent, follows up an idle one or
 *               revives a parked one; Escape clears the line, then returns
 *
 * The component holds view state only; the controller performs requests and
 * reports outcomes with {@link setFlash}. Every agent string is child output
 * and reaches the screen only through safeLine/safeText.
 */

import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import { card, EMPTY_NODE, node, span, text } from "@oh-my-pi/pi-tui/native/describe";
import type { NativeChild, NativeNode } from "@oh-my-pi/pi-tui/native/node";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth } from "@oh-my-pi/pi-tui/utils";
import { safeLine, safeText } from "../../formatters/base.ts";
import { compactCount } from "../../formatters/omp.ts";
import {
	isTaskActive,
	isTaskTerminal,
	type TaskRecord,
	type TaskStatus,
	type TaskTreeRow,
} from "../../store/task-store.ts";
import type { NoticeLevel } from "../../store/transcript-model.ts";
import { type ColorSlot, getTheme } from "../theme/theme.ts";
import { formatElapsed } from "./omp-panel.ts";
import { isPrintable } from "./pickers.ts";

/** The `agent` node's props, via pi-tui's node type (pi-wire is not a direct dependency). */
type AgentProps = NonNullable<Extract<NativeNode, { k: "agent" }>["p"]>;

/** Roster rows the row renderer shows at once; the selection scrolls the rest into view. */
export const HUB_ROSTER_WINDOW = 8;
/** Transcript rows the row renderer shows at once. */
export const HUB_TRANSCRIPT_WINDOW = 14;

export type HubView = "roster" | "transcript";
export type HubLayout = "tree" | "flat";

const AGENT_STATUS: Record<TaskStatus, AgentProps["status"]> = {
	queued: "pending",
	running: "running",
	cancelling: "running",
	idle: "idle",
	parked: "parked",
	completed: "done",
	error: "failed",
	aborted: "aborted",
	unknown: "idle",
};

/** The hub's status vocabulary: the daemon's `failed`/`cancelled` for terminal errors. */
const STATUS_LABEL: Record<TaskStatus, string> = {
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

const STATUS_SLOT: Record<TaskStatus, ColorSlot> = {
	queued: "text",
	running: "text",
	cancelling: "warning",
	idle: "info",
	parked: "muted",
	completed: "success",
	error: "error",
	aborted: "warning",
	unknown: "warning",
};

export interface HubFlash {
	text: string;
	level: NoticeLevel;
}

export interface HubTranscript {
	taskId: string;
	loading: boolean;
	text?: string;
	truncated?: boolean;
	error?: string;
}

export interface AgentHubHost {
	requestRender(): void;
	/** Escape out of the hub; the host hides it and restores editor focus. */
	onBlur(): void;
	/** Load (or reload) the transcript of one agent; report it with {@link AgentHubComponent.setTranscript}. */
	onOpen(taskId: string): void;
	/** Resolves true when the daemon accepted the message; the line is then cleared. */
	onSend(taskId: string, message: string): Promise<boolean>;
	onCancel(taskId: string): void;
	onRefresh(): void;
	now?: () => number;
}

export class AgentHubComponent implements Component {
	focused = false;
	readonly #host: AgentHubHost;
	#visible = false;
	#rows: readonly TaskTreeRow[] = [];
	#layout: HubLayout = "tree";
	#filter = "";
	#filtering = false;
	#selectedId: string | undefined;
	#view: HubView = "roster";
	#transcript: HubTranscript | undefined;
	#transcriptScroll = Number.POSITIVE_INFINITY;
	#input = "";
	#sending = false;
	#armedCancel: string | undefined;
	#flash: HubFlash | undefined;
	#revision = 0;
	#native: { revision: number; node: NativeNode } | undefined;

	constructor(host: AgentHubHost) {
		this.#host = host;
	}

	get visible(): boolean {
		return this.#visible;
	}

	get view(): HubView {
		return this.#view;
	}

	get layout(): HubLayout {
		return this.#layout;
	}

	get filter(): string {
		return this.#filter;
	}

	get flash(): HubFlash | undefined {
		return this.#flash;
	}

	/** The selected agent among the rows currently shown (filter and layout applied). */
	get selected(): TaskRecord | undefined {
		const rows = this.#shown();
		return (rows.find((row) => row.task.taskId === this.#selectedId) ?? rows[0])?.task;
	}

	/** The agent whose transcript is open, if any. */
	get openTaskId(): string | undefined {
		return this.#view === "transcript" ? this.#transcript?.taskId : undefined;
	}

	setVisible(visible: boolean): void {
		if (this.#visible === visible) return;
		this.#visible = visible;
		if (!visible) this.resetView();
		this.#changed();
	}

	/** Back to the roster with no open transcript, draft message, filter edit or flash. */
	resetView(): void {
		this.#view = "roster";
		this.#transcript = undefined;
		this.#input = "";
		this.#filtering = false;
		this.#armedCancel = undefined;
		this.#flash = undefined;
		this.#changed();
	}

	/** Rows in parent/child tree order; the selection follows its agent, not its index. */
	update(rows: readonly TaskTreeRow[]): void {
		this.#rows = rows;
		this.#changed();
	}

	setTranscript(transcript: HubTranscript): void {
		if (this.#transcript && this.#transcript.taskId !== transcript.taskId) return;
		const first = this.#transcript?.text === undefined;
		this.#transcript = transcript;
		if (first) this.#transcriptScroll = Number.POSITIVE_INFINITY;
		this.#changed();
		this.#host.requestRender();
	}

	setFlash(flash: HubFlash | undefined): void {
		this.#flash = flash;
		this.#changed();
		this.#host.requestRender();
	}

	invalidate(): void {
		// Nothing cached in row form: theme, focus and clocks are read at render time.
	}

	// -- input -----------------------------------------------------------------

	handleInput(data: string): void {
		if (this.#view === "transcript") this.#transcriptKey(data);
		else if (this.#filtering) this.#filterKey(data);
		else this.#rosterKey(data);
		this.#changed();
		this.#host.requestRender();
	}

	#rosterKey(data: string): void {
		const armed = this.#armedCancel;
		this.#armedCancel = undefined;
		if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) {
			if (this.#filter) this.#filter = "";
			else this.#host.onBlur();
			return;
		}
		const delta = data === "k" ? -1 : data === "j" ? 1 : navigationDelta(data, HUB_ROSTER_WINDOW);
		if (delta !== 0) {
			this.#move(delta);
			return;
		}
		const agent = this.selected;
		if (matchesKey(data, "enter")) {
			if (!agent) return;
			this.#view = "transcript";
			this.#transcript = { taskId: agent.taskId, loading: true };
			this.#transcriptScroll = Number.POSITIVE_INFINITY;
			this.#input = "";
			this.#flash = undefined;
			this.#host.onOpen(agent.taskId);
			return;
		}
		switch (data) {
			case "t":
				this.#layout = this.#layout === "tree" ? "flat" : "tree";
				return;
			case "/":
				this.#filtering = true;
				return;
			case "r":
				this.#host.onRefresh();
				return;
			case "x":
				if (!agent) return;
				if (agent.cancellable === false || isTaskTerminal(agent.status)) {
					this.#flash = { text: `${label(agent)} has already finished`, level: "warning" };
				} else if (armed === agent.taskId) {
					this.#host.onCancel(agent.taskId);
				} else {
					this.#armedCancel = agent.taskId;
					this.#flash = {
						text: `press x again to cancel ${label(agent)} — cancellation is final`,
						level: "warning",
					};
				}
				return;
		}
	}

	#filterKey(data: string): void {
		if (matchesKey(data, "escape")) {
			this.#filter = "";
			this.#filtering = false;
		} else if (matchesKey(data, "enter") || matchesKey(data, "down") || matchesKey(data, "up")) {
			this.#filtering = false;
		} else if (matchesKey(data, "backspace")) {
			this.#filter = this.#filter.slice(0, -1);
		} else if (matchesKey(data, "ctrl+u")) {
			this.#filter = "";
		} else if (isPrintable(data)) {
			this.#filter += data;
		}
	}

	#transcriptKey(data: string): void {
		if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) {
			if (this.#input && !this.#sending) this.#input = "";
			else {
				this.#view = "roster";
				this.#transcript = undefined;
				this.#flash = undefined;
			}
			return;
		}
		const delta = navigationDelta(data, HUB_TRANSCRIPT_WINDOW);
		if (delta !== 0) {
			const lines = this.#transcriptLines().length;
			const max = Math.max(0, lines - HUB_TRANSCRIPT_WINDOW);
			this.#transcriptScroll = Math.max(0, Math.min(max, this.#scrollTop(lines) + delta));
			return;
		}
		if (this.#sending) return;
		const agent = this.#openAgent();
		if (matchesKey(data, "enter")) {
			const message = this.#input.trim();
			if (message && agent) void this.#send(agent, message);
			return;
		}
		if (matchesKey(data, "backspace")) this.#input = this.#input.slice(0, -1);
		else if (matchesKey(data, "ctrl+u")) this.#input = "";
		else if (isPrintable(data)) {
			if (agent && messageable(agent)) this.#input += data;
			else
				this.#flash = {
					text: `${agent ? label(agent) : "this agent"} can no longer be messaged`,
					level: "warning",
				};
		}
	}

	async #send(agent: TaskRecord, message: string): Promise<void> {
		this.#sending = true;
		this.#changed();
		this.#host.requestRender();
		const accepted = await this.#host.onSend(agent.taskId, message);
		this.#sending = false;
		// A refused or unacknowledged message stays on the line for review.
		if (accepted) this.#input = "";
		this.#changed();
		this.#host.requestRender();
	}

	#move(delta: number): void {
		const rows = this.#shown();
		if (rows.length === 0) return;
		const current = Math.max(
			0,
			rows.findIndex((row) => row.task.taskId === this.selected?.taskId),
		);
		const next = Math.max(0, Math.min(rows.length - 1, current + delta));
		this.#selectedId = rows[next]!.task.taskId;
	}

	#openAgent(): TaskRecord | undefined {
		const id = this.#transcript?.taskId;
		return id ? this.#rows.find((row) => row.task.taskId === id)?.task : undefined;
	}

	// -- derived state -----------------------------------------------------------

	#shown(): readonly TaskTreeRow[] {
		const query = this.#filter.trim().toLowerCase();
		let rows = this.#rows;
		if (query) {
			rows = rows.filter(({ task }) =>
				[task.taskId, task.name, task.agent, task.description].some((field) =>
					field?.toLowerCase().includes(query),
				),
			);
		}
		if (this.#layout === "flat") {
			rows = [...rows]
				.sort(
					(a, b) =>
						OPERATIONAL_RANK[a.task.status] - OPERATIONAL_RANK[b.task.status] ||
						b.task.updatedAt - a.task.updatedAt,
				)
				.map(({ task }) => ({ task, depth: 0 }));
		}
		return rows;
	}

	#transcriptLines(): string[] {
		const transcript = this.#transcript;
		if (!transcript?.text) return [];
		return safeText(transcript.text).replace(/\s+$/, "").split("\n");
	}

	#scrollTop(lines: number): number {
		const max = Math.max(0, lines - HUB_TRANSCRIPT_WINDOW);
		return Math.min(this.#transcriptScroll, max);
	}

	#headline(): string {
		const tasks = this.#rows.map((row) => row.task);
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

	#changed(): void {
		this.#revision += 1;
	}

	// -- rows ------------------------------------------------------------------

	render(width: number): readonly string[] {
		if (!this.#visible || width <= 0) return EMPTY;
		const theme = getTheme();
		const clamp = (line: string) => truncateToWidth(line, width);
		const now = this.#host.now?.() ?? Date.now();
		const lines =
			this.#view === "transcript" ? this.#transcriptRows(now, clamp) : this.#rosterRows(now, clamp);
		if (this.#flash) lines.push(theme.fg(slotFor(this.#flash.level), clamp(this.#flash.text)));
		if (this.focused) lines.push(theme.fg("dim", clamp(this.#hint())));
		return lines;
	}

	#rosterRows(now: number, clamp: (line: string) => string): string[] {
		const theme = getTheme();
		const view = [
			this.#layout,
			this.#filter || this.#filtering ? `/${this.#filter}${this.#filtering ? "▏" : ""}` : "",
		]
			.filter(Boolean)
			.join(" · ");
		const lines = [theme.fg("accent", clamp(`agents · ${this.#headline()} · ${view}`))];
		const rows = this.#shown();
		if (rows.length === 0) {
			const empty = this.#rows.length === 0 ? "No subagents in this session." : "No agents match.";
			lines.push(theme.fg("dim", clamp(empty)));
			return lines;
		}
		const selectedId = this.selected?.taskId;
		const index = Math.max(
			0,
			rows.findIndex((row) => row.task.taskId === selectedId),
		);
		const start = Math.max(
			0,
			Math.min(index - HUB_ROSTER_WINDOW + 1, rows.length - HUB_ROSTER_WINDOW),
		);
		const end = Math.min(start + HUB_ROSTER_WINDOW, rows.length);
		for (let at = start; at < end; at++) {
			const { task, depth } = rows[at]!;
			const selected = this.focused && at === index;
			// Bound indentation even if the wire contains a very deep hierarchy.
			const indent = "  ".repeat(Math.min(depth, 5));
			const branch = depth > 0 ? "└─ " : "";
			const marker = selected ? theme.cursor : " ";
			const clock = clockText(task, now);
			const facts = [
				task.model ? safeLine(task.model, 40) : undefined,
				usageText(task.usage),
			].filter(Boolean);
			const row = `${marker} ${indent}${branch}${STATUS_LABEL[task.status]}${clock ? ` ${clock}` : ""} · ${identity(task)}${facts.length > 0 ? ` · ${facts.join(" · ")}` : ""}`;
			lines.push(theme.fg(selected ? "accent" : STATUS_SLOT[task.status], clamp(row)));
			if (task.progress) {
				lines.push(theme.fg("muted", clamp(`    ${indent}${safeLine(task.progress, 400)}`)));
			}
		}
		const hidden = rows.length - (end - start);
		if (hidden > 0) lines.push(theme.fg("dim", clamp(`  …${hidden} more · ↑↓ browse`)));
		const agent = this.selected;
		if (this.focused && agent) lines.push(theme.fg("dim", clamp(`  ${inspector(agent)}`)));
		return lines;
	}

	#transcriptRows(now: number, clamp: (line: string) => string): string[] {
		const theme = getTheme();
		const transcript = this.#transcript;
		const agent = this.#openAgent();
		const title = agent ? identity(agent) : safeLine(transcript?.taskId ?? "", 80);
		const status = agent
			? `${STATUS_LABEL[agent.status]}${clockText(agent, now) ? ` ${clockText(agent, now)}` : ""}`
			: "";
		const lines = [
			theme.fg("accent", clamp(`agents › ${title}${status ? ` · ${status}` : ""} · transcript`)),
		];
		if (!transcript || (transcript.loading && transcript.text === undefined)) {
			lines.push(theme.fg("dim", clamp("loading transcript…")));
		} else if (transcript.error && transcript.text === undefined) {
			lines.push(theme.fg("error", clamp(`transcript unavailable: ${transcript.error}`)));
		} else {
			const all = this.#transcriptLines();
			const top = this.#scrollTop(all.length);
			for (const line of all.slice(top, top + HUB_TRANSCRIPT_WINDOW)) {
				lines.push(clamp(`  ${line}`));
			}
			const below = Math.max(0, all.length - top - HUB_TRANSCRIPT_WINDOW);
			if (top > 0 || below > 0 || transcript.truncated) {
				const cut = transcript.truncated ? " · older history truncated" : "";
				lines.push(theme.fg("dim", clamp(`  ${top} above · ${below} below · ↑↓ scroll${cut}`)));
			}
		}
		if (agent && messageable(agent)) {
			const cursor = this.#sending ? "" : "▏";
			const sending = this.#sending ? " (sending…)" : "";
			lines.push(
				clamp(`${theme.fg("muted", `${sendVerb(agent)}${sending} › `)}${this.#input}${cursor}`),
			);
		} else {
			lines.push(theme.fg("dim", clamp("this agent can no longer be messaged")));
		}
		return lines;
	}

	#hint(): string {
		if (this.#view === "transcript") {
			return "type a message · enter send · ↑↓ scroll · esc clear/back";
		}
		if (this.#filtering) return "type to filter by id or name · enter keep · esc clear";
		const close = this.#filter ? "esc clear filter" : "esc close";
		return `↑↓ select · enter transcript & message · t ${this.#layout === "tree" ? "flat" : "tree"} · / filter · x cancel · r refresh · ${close}`;
	}

	// -- native (TSP) --------------------------------------------------------------

	/**
	 * omp's task card (`omp.tool.task`) holding one `agent` node per child at its
	 * lineage depth, or the open agent's transcript and message line.
	 */
	describe(): NativeNode {
		if (!this.#visible) return EMPTY_NODE;
		if (this.#native?.revision === this.#revision) return this.#native.node;
		const now = this.#host.now?.() ?? Date.now();
		const body: NativeChild[] = [];
		if (this.#view === "transcript") {
			const agent = this.#openAgent();
			if (agent) body.push(agentNode(agent, 0, now, false));
			const transcript = this.#transcript;
			if (transcript?.text !== undefined) {
				body.push(text([span(safeText(transcript.text))], { wrap: "word", key: "transcript" }));
			} else {
				body.push(
					text(
						[
							span(
								transcript?.error
									? `transcript unavailable: ${transcript.error}`
									: "loading transcript…",
								"dim",
							),
						],
						{
							key: "transcript",
						},
					),
				);
			}
			if (agent && messageable(agent)) {
				body.push(
					text([span(`${sendVerb(agent)} › `, "muted"), span(this.#input)], { key: "input" }),
				);
			}
		} else {
			const rows = this.#shown();
			const selectedId = this.selected?.taskId;
			for (const { task, depth } of rows) {
				body.push(agentNode(task, depth, now, this.focused && task.taskId === selectedId));
			}
			if (rows.length === 0) {
				body.push(
					text(
						[
							span(
								this.#rows.length === 0 ? "No subagents in this session." : "No agents match.",
								"dim",
							),
						],
						{
							key: "empty",
						},
					),
				);
			}
		}
		if (this.#flash) {
			body.push(
				text([span(this.#flash.text, toneFor(this.#flash.level))], { wrap: "word", key: "flash" }),
			);
		}
		if (this.focused) body.push(text([span(this.#hint(), "dim")], { key: "hint" }));
		const active = this.#rows.some((row) => isTaskActive(row.task.status));
		const described = card(
			{
				role: "omp.tool.task",
				head: [span("Agents", "strong"), span(` · ${this.#headline()}`, "muted")],
				status: active ? "running" : "done",
			},
			body,
		);
		this.#native = { revision: this.#revision, node: described };
		return described;
	}
}

const EMPTY: readonly string[] = Object.freeze([]);

function agentNode(task: TaskRecord, depth: number, now: number, selected: boolean): NativeNode {
	const ms = clockMs(task, now);
	const usage = task.usage;
	const props: AgentProps = {
		name: label(task),
		status: AGENT_STATUS[task.status],
		role: "omp.task.agent",
		...(task.agent ? { agent: safeLine(task.agent, 40) } : {}),
		...(task.description ? { task: safeLine(task.description) } : {}),
		...(task.model ? { model: safeLine(task.model, 60) } : {}),
		stats: {
			...(usage?.tokens !== undefined ? { tokens: usage.tokens } : {}),
			...(usage?.requests !== undefined ? { requests: usage.requests } : {}),
			...(usage?.costUsd !== undefined ? { cost: usage.costUsd } : {}),
			...(task.contextPercent !== undefined
				? { context: Math.min(1, Math.max(0, task.contextPercent / 100)) }
				: {}),
			...(ms === undefined ? {} : isTaskTerminal(task.status) ? { took: ms } : { age: ms }),
		},
		badges: [
			...(selected ? [{ text: "selected", tone: "accent" as const }] : []),
			...(task.status === "unknown"
				? [{ text: "outcome unknown", tone: "warning" as const }]
				: task.status === "cancelling"
					? [{ text: "cancelling", tone: "warning" as const }]
					: []),
		],
		...(depth > 0 ? { depth } : {}),
		...(task.progress ? { collapsible: true, collapsed: false } : {}),
	};
	return node(
		"agent",
		props,
		task.progress ? [text([span(safeLine(task.progress, 400), "muted")], { wrap: "word" })] : [],
		task.taskId,
	);
}

function label(task: TaskRecord): string {
	return safeLine(task.name ?? task.description ?? task.taskId, 80) || task.taskId;
}

/** `Researcher @scout · 3f2a…`: name or assignment, persona, and the opaque ID when it differs. */
function identity(task: TaskRecord): string {
	const id = safeLine(task.taskId, 40);
	const shown = label(task);
	const agent = task.agent ? ` @${safeLine(task.agent, 40)}` : "";
	return `${shown}${agent}${shown !== id ? ` · ${id}` : ""}`;
}

/** Running/queued: time since start; idle/parked: time since the last turn ended; finished: how long it took. */
function clockMs(task: TaskRecord, now: number): number | undefined {
	if (task.status === "unknown") return undefined;
	if (task.status === "idle" || task.status === "parked") {
		return task.finishedAt === undefined ? undefined : Math.max(0, now - task.finishedAt);
	}
	return Math.max(0, (task.finishedAt ?? now) - task.observedAt);
}

function clockText(task: TaskRecord, now: number): string {
	const ms = clockMs(task, now);
	return ms === undefined ? "" : formatElapsed(ms);
}

function messageable(task: TaskRecord): boolean {
	if (task.messaging !== undefined) return task.messaging;
	return isTaskActive(task.status) || task.status === "idle" || task.status === "parked";
}

function sendVerb(task: TaskRecord): string {
	return task.status === "idle" ? "follow up" : task.status === "parked" ? "revive" : "steer";
}

function inspector(task: TaskRecord): string {
	return [
		`task ${safeLine(task.taskId, 40)}`,
		task.parentTaskId ? `parent ${safeLine(task.parentTaskId, 40)}` : undefined,
		task.contextPercent !== undefined ? `ctx ${task.contextPercent.toFixed(0)}%` : undefined,
		task.description && task.name ? safeLine(task.description, 160) : undefined,
	]
		.filter(Boolean)
		.join(" · ");
}

function totalUsage(tasks: readonly TaskRecord[]): TaskRecord["usage"] {
	const total: NonNullable<TaskRecord["usage"]> = {};
	for (const task of tasks) {
		for (const field of ["tokens", "costUsd", "requests"] as const) {
			const value = task.usage?.[field];
			if (value !== undefined) total[field] = (total[field] ?? 0) + value;
		}
	}
	return total;
}

/** `12.4k tok · $0.12 · 31 req`; unknown counters are omitted, never shown as zero. */
function usageText(usage: TaskRecord["usage"]): string | undefined {
	if (!usage) return undefined;
	const parts: string[] = [];
	if (usage.tokens !== undefined) parts.push(`${compactCount(usage.tokens)} tok`);
	if (usage.costUsd !== undefined) {
		parts.push(`$${usage.costUsd.toFixed(usage.costUsd < 0.01 ? 4 : 2)}`);
	}
	if (usage.requests !== undefined) parts.push(`${usage.requests} req`);
	return parts.length > 0 ? parts.join(" ") : undefined;
}

function navigationDelta(data: string, page: number): number {
	if (matchesKey(data, "up") || matchesKey(data, "ctrl+p")) return -1;
	if (matchesKey(data, "down") || matchesKey(data, "ctrl+n")) return 1;
	if (matchesKey(data, "pageUp")) return -page;
	if (matchesKey(data, "pageDown")) return page;
	return 0;
}

function slotFor(level: NoticeLevel): ColorSlot {
	return level === "error" ? "error" : level === "warning" ? "warning" : "muted";
}

function toneFor(level: NoticeLevel): string {
	return level === "error" ? "error" : level === "warning" ? "warning" : "muted";
}
