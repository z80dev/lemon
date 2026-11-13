/**
 * The agent hub: every subagent of the focused session in one live table, and a
 * scrollable transcript for the one you open.
 *
 * omp's hub (pi-tui `overlays/agent-hub`) reads an in-process agent registry and
 * tails session JSONL files; Lemon's children live in the daemon, so this is the
 * same UX built on Lemon's data. The table is the {@link TaskFeed} (rows from the
 * task tree, refreshed on every change); a transcript is the child's
 * `chat.history`, re-read on a bounded timer while the child is still active.
 *
 * Nothing here estimates anything: a child with no recorded session says so
 * rather than showing the parent's text, and a failed read stays visible next to
 * whatever was last loaded.
 */

import { Markdown } from "@oh-my-pi/pi-tui/components/markdown";
import { renderTableRow, type TableColumn } from "@oh-my-pi/pi-tui/components/table";
import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth, visibleWidth, wrapTextWithAnsi } from "@oh-my-pi/pi-tui/utils";
import { sanitizeText } from "@oh-my-pi/pi-utils/sanitize-text";
import { describeError } from "../../protocol/errors.ts";
import type { ChatHistoryMessage } from "../../protocol/types.ts";
import {
	type AgentHubRow,
	formatElapsed,
	projectAgentHubRows,
	summarizeAgentHubRows,
} from "../agent-hub-rows.ts";
import type { TaskFeed } from "../controllers/task-tree-controller.ts";
import { type ColorSlot, getTheme } from "../theme/theme.ts";
import { getMarkdownTheme } from "../theme/tui-adapters.ts";

/** Refresh cadence for an open transcript whose child is still running. */
export const AGENT_HUB_POLL_MS = 1500;
/** Consecutive failed reads before polling stops (`r` retries). */
export const AGENT_HUB_MAX_FAILURES = 3;
/** Table rows that are chrome: title, column header, footer. */
const TABLE_CHROME = 3;
/** Selected-child detail under the table: rule, identity, two lines of progress. */
const DETAIL_ROWS = 4;
const TRANSCRIPT_CHROME = 3;

export interface AgentHubOptions {
	feed: TaskFeed;
	/** The child's messages, oldest first. Absent when the daemon cannot serve history. */
	loadTranscript?: (row: AgentHubRow) => Promise<readonly ChatHistoryMessage[]>;
	rows: () => number;
	close: () => void;
	repaint: () => void;
	now?: () => number;
	pollMs?: number;
	tickMs?: number;
}

interface TranscriptState {
	taskId: string;
	messages: readonly ChatHistoryMessage[] | undefined;
	error: string | undefined;
	loading: boolean;
	failures: number;
	version: number;
	offset: number;
	/** Stay pinned to the newest line until the reader scrolls up. */
	follow: boolean;
	timer: ReturnType<typeof setTimeout> | undefined;
	/** The fetch that observed the child already finished; nothing newer can arrive. */
	settled: boolean;
	lines: { key: string; rows: readonly string[] } | undefined;
	total: number;
	page: number;
}

const STATUS_SLOT: Record<AgentHubRow["status"], ColorSlot> = {
	queued: "muted",
	running: "toolRunning",
	cancelling: "warning",
	completed: "success",
	error: "error",
	aborted: "warning",
	unknown: "muted",
};

const GLYPHS: Record<"unicode" | "ascii", Record<AgentHubRow["status"], string>> = {
	unicode: {
		queued: "○",
		running: "●",
		cancelling: "◐",
		completed: "✓",
		error: "✗",
		aborted: "■",
		unknown: "?",
	},
	ascii: {
		queued: "o",
		running: "*",
		cancelling: "~",
		completed: "+",
		error: "x",
		aborted: "-",
		unknown: "?",
	},
};

function glyph(status: AgentHubRow["status"]): string {
	return GLYPHS[getTheme().getSymbolPreset()][status];
}

/** First non-blank line of untrusted transcript text, escape-free via `sanitizeText`. */
function firstLine(text: string): string {
	return (
		sanitizeText(text)
			.split("\n")
			.find((line) => line.trim() !== "")
			?.trim() ?? ""
	);
}

export class AgentHubComponent implements Component {
	readonly #options: AgentHubOptions;
	readonly #unsubscribe: () => void;
	readonly #tick: ReturnType<typeof setInterval>;
	#rows: AgentHubRow[] = [];
	#selected = 0;
	#offset = 0;
	#view: "table" | "transcript" = "table";
	#transcript: TranscriptState | undefined;
	#disposed = false;

	constructor(options: AgentHubOptions) {
		this.#options = options;
		this.#project();
		this.#unsubscribe = options.feed.subscribe(() => this.#changed());
		this.#tick = setInterval(() => {
			if (this.#rows.some((row) => row.active)) options.repaint();
		}, options.tickMs ?? 1000);
		this.#tick.unref?.();
	}

	get view(): "table" | "transcript" {
		return this.#view;
	}

	get rows(): readonly AgentHubRow[] {
		return this.#rows;
	}

	get selected(): AgentHubRow | undefined {
		return this.#rows[this.#selected];
	}

	/** Releases the feed subscription and every timer; the host calls it when the overlay goes away. */
	dispose(): void {
		if (this.#disposed) return;
		this.#disposed = true;
		this.#unsubscribe();
		clearInterval(this.#tick);
		this.#stopPolling();
	}

	invalidate(): void {
		if (this.#transcript) this.#transcript.lines = undefined;
	}

	handleInput(data: string): void {
		if (this.#disposed) return;
		if (matchesKey(data, "ctrl+c")) {
			this.#options.close();
			return;
		}
		if (this.#view === "transcript") this.#transcriptKey(data);
		else this.#tableKey(data);
	}

	render(width: number): readonly string[] {
		if (width < 1) return [];
		return this.#view === "transcript" ? this.#renderTranscript(width) : this.#renderTable(width);
	}

	// -- table ----------------------------------------------------------------

	#tableKey(data: string): void {
		if (matchesKey(data, "escape") || data === "q") {
			this.#options.close();
			return;
		}
		if (matchesKey(data, "enter")) {
			const row = this.selected;
			if (row) this.#openTranscript(row);
			return;
		}
		const page = this.#tablePage();
		let selected = this.#selected;
		if (matchesKey(data, "up") || matchesKey(data, "ctrl+p") || data === "k") selected--;
		else if (matchesKey(data, "down") || matchesKey(data, "ctrl+n") || data === "j") selected++;
		else if (matchesKey(data, "pageUp")) selected -= page;
		else if (matchesKey(data, "pageDown")) selected += page;
		else if (matchesKey(data, "home") || data === "g") selected = 0;
		else if (matchesKey(data, "end") || data === "G") selected = this.#rows.length - 1;
		else return;
		this.#selected = Math.max(0, Math.min(selected, this.#rows.length - 1));
		this.#options.repaint();
	}

	#tablePage(): number {
		return Math.max(1, this.#options.rows() - TABLE_CHROME - DETAIL_ROWS);
	}

	#renderTable(width: number): readonly string[] {
		const theme = getTheme();
		const clamp = (text: string) => truncateToWidth(text, width);
		const summary = summarizeAgentHubRows(this.#rows);
		const noun = summary.total === 1 ? "agent" : "agents";
		const failed = summary.failed > 0 ? ` · ${summary.failed} failed` : "";
		const lines: string[] = [
			clamp(
				theme.fg("accent", theme.bold("Agent hub")) +
					theme.fg("dim", ` · ${summary.total} ${noun} · ${summary.active} running${failed}`),
			),
		];
		const page = this.#tablePage();
		if (this.#rows.length === 0) {
			lines.push("");
			lines.push(clamp(theme.fg("muted", "No subagents in this session yet.")));
			lines.push(
				...wrapTextWithAnsi(
					theme.fg("dim", "Children appear here, live, as the task tool launches them."),
					width,
				),
			);
		} else {
			if (this.#selected < this.#offset) this.#offset = this.#selected;
			if (this.#selected >= this.#offset + page) this.#offset = this.#selected - page + 1;
			this.#offset = Math.max(0, Math.min(this.#offset, this.#rows.length - page));
			const columns = this.#columns(width);
			lines.push(
				clamp(
					theme.fg(
						"dim",
						renderTableRow(
							["status", "age", "agent", "task", "latest"].map((text) => ({ text })),
							columns,
							width,
							{ indent: "  ", gap: "  " },
						),
					),
				),
			);
			const end = Math.min(this.#rows.length, this.#offset + page);
			for (let index = this.#offset; index < end; index++) {
				lines.push(this.#tableRow(this.#rows[index]!, index === this.#selected, columns, width));
			}
		}
		// Pin the detail and footer to the bottom of the overlay.
		const bodyEnd = TABLE_CHROME - 1 + page;
		while (lines.length < bodyEnd) lines.push("");
		lines.push(...this.#detail(width));
		const position = this.#rows.length ? `${this.#selected + 1}/${this.#rows.length} · ` : "";
		const keys =
			width >= 64
				? "↑↓/pgup/pgdn select · enter transcript · g/G first/last · esc close"
				: "↑↓ select · enter open · esc close";
		lines.push(clamp(theme.fg("dim", `${position}${keys}`)));
		return lines;
	}

	#columns(width: number): TableColumn[] {
		// The task and latest columns share what the fixed ones leave; `latest` yields first.
		const fixed = 2 + 11 + 7 + 14 + 4 * 2;
		const flexible = Math.max(10, width - fixed);
		const task = Math.max(8, Math.floor(flexible * 0.45));
		return [
			{ width: 11, align: "left", overflow: "truncate", priority: 4 },
			{ width: 7, align: "right", overflow: "truncate", priority: 4 },
			{ width: 14, align: "left", overflow: "truncate", priority: 1 },
			{ width: task, align: "left", overflow: "truncate", priority: 3, minWidth: 8 },
			{ width: Math.max(8, flexible - task), align: "left", overflow: "truncate", priority: 0 },
		];
	}

	#tableRow(row: AgentHubRow, selected: boolean, columns: TableColumn[], width: number): string {
		const theme = getTheme();
		const status = `${glyph(row.status)} ${row.status}`;
		const age = formatElapsed(row.elapsedMs ?? undefined);
		const indent = "  ".repeat(Math.min(row.depth, 4)) + (row.depth > 0 ? "└ " : "");
		const style = (slot: ColorSlot) =>
			selected ? undefined : (text: string) => theme.fg(slot, text);
		const cells = [
			{ text: status, style: style(STATUS_SLOT[row.status]) },
			{ text: age, style: style("dim") },
			{ text: row.agent ? `@${row.agent}` : "", style: style("muted") },
			{ text: `${indent}${row.label}`, style: style("text") },
			{ text: row.progress ?? "", style: style("muted") },
		];
		const marker = selected ? theme.cursor : " ";
		const line = `${marker} ${renderTableRow(cells, columns, width - 2, { gap: "  " })}`;
		const clipped = truncateToWidth(line, width);
		if (!selected) return clipped;
		const pad = Math.max(0, width - visibleWidth(clipped));
		return theme.bg("selectedBg", theme.fg("accent", clipped + " ".repeat(pad)));
	}

	/** The selected child: identity and its latest progress, wrapped rather than cut. */
	#detail(width: number): string[] {
		const theme = getTheme();
		const lines = [truncateToWidth(theme.fg("border", theme.hrChar.repeat(width)), width)];
		const row = this.selected;
		if (!row) {
			while (lines.length < DETAIL_ROWS) lines.push("");
			return lines;
		}
		const identity = [
			`task ${row.taskId}`,
			row.sessionId ? `session ${row.sessionId}` : "no session yet",
		];
		lines.push(truncateToWidth(theme.fg("dim", identity.join(" · ")), width));
		const progress = row.progress
			? wrapTextWithAnsi(theme.fg("muted", row.progress), width).slice(0, DETAIL_ROWS - 2)
			: [theme.fg("dim", "No progress reported yet.")];
		lines.push(...progress.map((line) => truncateToWidth(line, width)));
		while (lines.length < DETAIL_ROWS) lines.push("");
		return lines;
	}

	// -- data -----------------------------------------------------------------

	#project(): void {
		const selectedId = this.selected?.taskId;
		this.#rows = projectAgentHubRows(
			this.#options.feed.rows(),
			this.#options.now?.() ?? Date.now(),
		);
		const index = selectedId ? this.#rows.findIndex((row) => row.taskId === selectedId) : -1;
		this.#selected =
			index >= 0 ? index : Math.max(0, Math.min(this.#selected, this.#rows.length - 1));
	}

	#changed(): void {
		if (this.#disposed) return;
		this.#project();
		const state = this.#transcript;
		if (state && this.#view === "transcript") {
			const row = this.#rows.find((candidate) => candidate.taskId === state.taskId);
			// A session id that just arrived, or a child that just finished and owes one last read.
			if (row && !state.timer && this.#wantsRead(state, row)) this.#fetch(state, row);
		}
		this.#options.repaint();
	}

	// -- transcript -----------------------------------------------------------

	#openTranscript(row: AgentHubRow): void {
		this.#stopPolling();
		const state: TranscriptState = {
			taskId: row.taskId,
			messages: undefined,
			error: undefined,
			loading: false,
			failures: 0,
			version: 0,
			offset: 0,
			follow: true,
			timer: undefined,
			settled: false,
			lines: undefined,
			total: 0,
			page: 1,
		};
		this.#transcript = state;
		this.#view = "transcript";
		this.#fetch(state, row);
		this.#options.repaint();
	}

	#closeTranscript(): void {
		this.#stopPolling();
		this.#transcript = undefined;
		this.#view = "table";
		this.#options.repaint();
	}

	#stopPolling(): void {
		const state = this.#transcript;
		if (!state) return;
		clearTimeout(state.timer);
		state.timer = undefined;
	}

	#fetch(state: TranscriptState, row: AgentHubRow): void {
		const load = this.#options.loadTranscript;
		if (!load || !row.sessionId || state.loading) return;
		state.loading = true;
		// Whether the child had already finished when this read began decides if it can still grow.
		const finished = !row.active;
		void Promise.resolve()
			.then(() => load(row))
			.then(
				(messages) => {
					if (this.#transcript !== state || this.#disposed) return;
					state.messages = messages;
					state.error = undefined;
					state.failures = 0;
					state.version++;
					if (finished) state.settled = true;
				},
				(error: unknown) => {
					if (this.#transcript !== state || this.#disposed) return;
					state.error = describeError(error);
					state.failures++;
				},
			)
			.finally(() => {
				state.loading = false;
				if (this.#transcript !== state || this.#disposed) return;
				this.#schedule(state);
				this.#options.repaint();
			});
	}

	/** Whether another read can add something: first load, a live child, or one last read after it ends. */
	#wantsRead(state: TranscriptState, row: AgentHubRow): boolean {
		return (
			this.#options.loadTranscript !== undefined &&
			row.sessionId !== undefined &&
			state.failures < AGENT_HUB_MAX_FAILURES &&
			(state.messages === undefined || row.active || !state.settled)
		);
	}

	/** Poll only while a read can still add messages and reads keep working. */
	#schedule(state: TranscriptState): void {
		clearTimeout(state.timer);
		state.timer = undefined;
		const row = this.#rows.find((candidate) => candidate.taskId === state.taskId);
		if (!row || !this.#wantsRead(state, row)) return;
		state.timer = setTimeout(() => {
			state.timer = undefined;
			if (this.#transcript !== state || this.#disposed) return;
			const current = this.#rows.find((candidate) => candidate.taskId === state.taskId);
			if (current) this.#fetch(state, current);
		}, this.#options.pollMs ?? AGENT_HUB_POLL_MS);
		state.timer.unref?.();
	}

	#transcriptKey(data: string): void {
		const state = this.#transcript;
		if (!state) return;
		if (
			matchesKey(data, "escape") ||
			matchesKey(data, "backspace") ||
			matchesKey(data, "left") ||
			data === "q"
		) {
			this.#closeTranscript();
			return;
		}
		if (data === "r") {
			state.failures = 0;
			const row = this.#rows.find((candidate) => candidate.taskId === state.taskId);
			if (row) this.#fetch(state, row);
			this.#options.repaint();
			return;
		}
		const max = Math.max(0, state.total - state.page);
		let offset = state.follow ? max : state.offset;
		if (matchesKey(data, "down") || data === "j") offset++;
		else if (matchesKey(data, "up") || data === "k") offset--;
		else if (matchesKey(data, "pageDown") || data === " ") offset += state.page;
		else if (matchesKey(data, "pageUp")) offset -= state.page;
		else if (matchesKey(data, "home") || data === "g") offset = 0;
		else if (matchesKey(data, "end") || data === "G") offset = max;
		else return;
		state.offset = Math.max(0, Math.min(offset, max));
		state.follow = state.offset >= max;
		this.#options.repaint();
	}

	#renderTranscript(width: number): readonly string[] {
		const state = this.#transcript;
		const row = state && this.#rows.find((candidate) => candidate.taskId === state.taskId);
		if (!state || !row) return this.#renderMissing(width);
		const theme = getTheme();
		const clamp = (text: string) => truncateToWidth(text, width);
		const elapsed = formatElapsed(row.elapsedMs ?? undefined);
		const mark = theme.fg(STATUS_SLOT[row.status], glyph(row.status));
		const identity = [
			row.agent ? `@${row.agent}` : "",
			`task ${row.taskId}`,
			row.sessionId ? `session ${row.sessionId}` : "",
		];
		const head = [
			clamp(
				`${mark} ${theme.fg("accent", theme.bold(row.label))}` +
					theme.fg("dim", ` · ${row.status}${elapsed ? ` · ${elapsed}` : ""}`),
			),
			clamp(theme.fg("dim", identity.filter(Boolean).join(" · "))),
		];
		const page = Math.max(1, this.#options.rows() - TRANSCRIPT_CHROME);
		const key = [
			width,
			state.version,
			state.error,
			state.loading,
			row.progress,
			row.sessionId,
		].join("|");
		if (state.lines?.key !== key) {
			state.lines = { key, rows: this.#transcriptBody(state, row, width) };
		}
		const body = state.lines.rows;
		const max = Math.max(0, body.length - page);
		state.total = body.length;
		state.page = page;
		state.offset = state.follow ? max : Math.max(0, Math.min(state.offset, max));
		const shown = body.slice(state.offset, state.offset + page);
		while (shown.length < page) shown.push("");
		const last = state.offset + Math.min(page, body.length);
		const where = body.length ? `${state.offset + 1}–${last}/${body.length}` : "0/0";
		const live = row.active
			? state.failures >= AGENT_HUB_MAX_FAILURES
				? "stalled — r retries"
				: state.follow
					? "live"
					: "live (scrolled)"
			: "finished";
		const keys =
			width >= 72
				? "↑↓/pgup/pgdn scroll · g/G top/bottom · r refresh · esc back"
				: "↑↓ scroll · esc back";
		return [...head, ...shown, clamp(theme.fg("dim", `${where} · ${live} · ${keys}`))];
	}

	/** The child vanished from the tree while its transcript was open (session reset). */
	#renderMissing(width: number): readonly string[] {
		const theme = getTheme();
		return [
			truncateToWidth(theme.fg("warning", "This agent is no longer in the session."), width),
			truncateToWidth(theme.fg("dim", "esc back"), width),
		];
	}

	#transcriptBody(state: TranscriptState, row: AgentHubRow, width: number): string[] {
		const theme = getTheme();
		const lines: string[] = [""];
		const note = (text: string, slot: ColorSlot = "muted") => {
			for (const line of wrapTextWithAnsi(theme.fg(slot, text), width)) lines.push(line);
		};
		if (!this.#options.loadTranscript) {
			note("This daemon does not serve session history, so the transcript is unavailable.");
		} else if (!row.sessionId) {
			note("This child has not reported a session yet; its transcript starts once it does.");
		} else if (state.messages === undefined && !state.error) {
			note("Loading transcript…", "dim");
		}
		if (state.error) note(`Could not read the transcript: ${state.error}`, "warning");
		if (state.messages !== undefined) {
			const rendered = transcriptLines(state.messages, width);
			if (rendered.length === 0) {
				note("No transcript recorded for this child yet.", "dim");
			} else {
				lines.push(...rendered);
			}
		}
		if (row.progress) {
			lines.push("");
			note(`latest: ${row.progress}`, "dim");
		}
		return lines;
	}
}

/**
 * Messages to terminal rows at `width`. A tool call and its result (same
 * `toolCallId`) collapse into the result's single line; text is escaped,
 * assistant text is Markdown. Never wider than `width`.
 */
export function transcriptLines(messages: readonly ChatHistoryMessage[], width: number): string[] {
	const theme = getTheme();
	const answered = new Set<string>();
	for (const message of messages) {
		if (message.role === "tool_result" && message.toolCallId) answered.add(message.toolCallId);
	}
	const indent = "  ";
	const inner = Math.max(1, width - indent.length);
	const out: string[] = [];
	const block = (label: string, slot: ColorSlot, body: readonly string[]) => {
		if (out.length > 0) out.push("");
		out.push(truncateToWidth(theme.fg(slot, theme.bold(label)), width));
		for (const line of body) out.push(truncateToWidth(`${indent}${line}`, width));
	};
	for (const message of messages) {
		const role = message.role;
		if (role === "tool_use" && message.toolCallId && answered.has(message.toolCallId)) continue;
		const text = typeof message.content === "string" ? message.content : "";
		const suffix = message.truncated ? [theme.fg("dim", "… (truncated)")] : [];
		if (role === "user") {
			block("you", "userPrefix", [
				...wrapTextWithAnsi(theme.fg("userText", sanitizeText(text)), inner),
				...suffix,
			]);
		} else if (role === "assistant") {
			if (sanitizeText(text).trim() === "") continue;
			const markdown = new Markdown(sanitizeText(text), 0, 0, getMarkdownTheme(), {
				color: (value) => theme.fg("assistantText", value),
			});
			block("assistant", "accent", [...markdown.render(inner), ...suffix]);
		} else if (role === "tool_use" || role === "tool_result") {
			const name = typeof message.toolName === "string" ? sanitizeText(message.toolName) : "tool";
			const title = typeof message.title === "string" ? sanitizeText(message.title) : "";
			const mark =
				role === "tool_use"
					? theme.fg("toolRunning", "…")
					: message.cancelled
						? theme.fg("warning", "■")
						: message.ok === false
							? theme.fg("toolError", "✗")
							: theme.fg("toolSuccess", "✓");
			const label = title && title !== name ? `${name} — ${title}` : name;
			out.push(truncateToWidth(`${indent}${mark} ${theme.fg("toolTitle", label)}`, width));
			const detail = role === "tool_result" ? firstLine(text) : "";
			if (detail) out.push(truncateToWidth(`${indent}  ${theme.fg("toolDetail", detail)}`, width));
		} else if (sanitizeText(text).trim() !== "") {
			block(sanitizeText(String(role)), "muted", [
				...wrapTextWithAnsi(theme.fg("muted", firstLine(text)), inner),
			]);
		}
	}
	return out;
}
