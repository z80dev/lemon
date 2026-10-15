/**
 * The `/omp` (Alt+M) panel: omp delegate sessions the daemon runs, modeled on
 * the task tree. Mounted in the dock outside the transcript, so live updates
 * never enter scrollback.
 *
 *   list      live and recent sessions; ↑↓ select, Enter opens the detail
 *   detail    one session's activity, tools, todos, subagents, usage and text;
 *             ↑↓ scroll, Enter returns to the list
 *   discover  omp session files for the TUI's working directory; Enter resumes
 *
 * In list and detail, `s` steers and `f` queues a follow-up (an inline text
 * field, as in the session switcher), `c` cancels the running turn, `x` closes
 * the process, `r` refreshes, `d` discovers. Escape leaves the text field or
 * discovery first, then closes the panel.
 *
 * The component holds view state only. Every request goes through the host
 * callbacks, which report their outcome back with {@link setFlash}.
 */

import { basename } from "node:path";
import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import { card, EMPTY_NODE, span, text } from "@oh-my-pi/pi-tui/native/describe";
import type { NativeChild, NativeNode } from "@oh-my-pi/pi-tui/native/node";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth } from "@oh-my-pi/pi-tui/utils";
import { safeLine, safeText } from "../../formatters/base.ts";
import {
	OMP_STATUS_GLYPHS,
	ompSessionLabel,
	ompStatusText,
	ompTodoProgress,
	ompUsageText,
} from "../../formatters/omp.ts";
import {
	isOmpSessionBusy,
	isOmpSessionEnded,
	type OmpDiscoveredSession,
	type OmpSendMode,
	type OmpSession,
} from "../../protocol/omp.ts";
import type { NoticeLevel } from "../../store/transcript-model.ts";
import { ompAgentNode, ompDetailNodes, ompElapsedMs } from "../omp-nodes.ts";
import { type ColorSlot, getTheme } from "../theme/theme.ts";
import { isPrintable } from "./pickers.ts";

/** Session rows the row renderer shows at once; the selection scrolls the rest into view. */
export const OMP_PANEL_WINDOW = 6;
/** Detail rows the row renderer shows at once. */
export const OMP_DETAIL_WINDOW = 14;

export type OmpPanelMode = "list" | "detail" | "discover";

export interface OmpPanelFlash {
	text: string;
	level: NoticeLevel;
}

export interface OmpPanelHost {
	requestRender(): void;
	/** Escape out of the panel; the host hides it and restores editor focus. */
	onBlur(): void;
	/** Resolves true when the daemon accepted the message (the field is then cleared). */
	onSend(session: OmpSession, mode: OmpSendMode, message: string): Promise<boolean>;
	onCancel(session: OmpSession): void;
	onClose(session: OmpSession): void;
	onRefresh(): void;
	onDiscover(): void;
	onResume(row: OmpDiscoveredSession): void;
	onContinue?(row: OmpDiscoveredSession): void;
	onConfigure?(session: OmpSession): void;
	onApproval?(session: OmpSession, id: string, decision: "approve_once" | "deny"): void;
	onSubagent?(session: OmpSession, id: string): void;
	now?: () => number;
}

interface PromptState {
	mode: OmpSendMode;
	sessionId: string;
	text: string;
	sending: boolean;
}

export interface OmpDiscoverState {
	cwd: string;
	rows: readonly OmpDiscoveredSession[];
	loading: boolean;
	error?: string;
}

export class OmpPanelComponent implements Component {
	focused = false;
	readonly #host: OmpPanelHost;
	#visible = false;
	#mode: OmpPanelMode = "list";
	#sessions: readonly OmpSession[] = [];
	#selectedId: string | undefined;
	#selected = 0;
	#detailScroll = 0;
	#discover: OmpDiscoverState | undefined;
	#discoverSelected = 0;
	#prompt: PromptState | undefined;
	#flash: OmpPanelFlash | undefined;
	#unavailable: string | undefined;
	#revision = 0;
	#native: { revision: number; node: NativeNode } | undefined;
	#approvalSelected = 0;
	#subagentSelected = 0;
	#viewer:
		| { title: string; rows: string[]; selected: number; choose?: (index: number) => void }
		| undefined;

	constructor(host: OmpPanelHost) {
		this.#host = host;
	}

	get visible(): boolean {
		return this.#visible;
	}

	get mode(): OmpPanelMode {
		return this.#mode;
	}

	get selected(): OmpSession | undefined {
		return this.#sessions[this.#selected];
	}

	get selectedDiscovered(): OmpDiscoveredSession | undefined {
		return this.#discover?.rows[this.#discoverSelected];
	}

	/** The inline text field, while one is open. */
	get prompt(): Readonly<PromptState> | undefined {
		return this.#prompt;
	}

	get flash(): OmpPanelFlash | undefined {
		return this.#flash;
	}

	setVisible(visible: boolean): void {
		if (this.#visible === visible) return;
		this.#visible = visible;
		if (!visible) this.#viewer = undefined;
		if (!visible) {
			this.#mode = "list";
			this.#prompt = undefined;
			this.#discover = undefined;
		}
		this.#changed();
	}

	/** Latest sessions in display order; the selection follows its session, not its index. */
	update(sessions: readonly OmpSession[]): void {
		this.#sessions = sessions;
		const index = this.#selectedId
			? sessions.findIndex((session) => session.id === this.#selectedId)
			: -1;
		this.#selected =
			index >= 0 ? index : Math.max(0, Math.min(this.#selected, sessions.length - 1));
		this.#selectedId = sessions[this.#selected]?.id;
		this.#changed();
	}

	/** Why omp cannot be used here (no omp.* methods, omp not installed), or undefined. */
	setUnavailable(reason: string | undefined): void {
		if (this.#unavailable === reason) return;
		this.#unavailable = reason;
		this.#changed();
	}

	setFlash(flash: OmpPanelFlash | undefined): void {
		this.#flash = flash;
		this.#changed();
		this.#host.requestRender();
	}

	setDiscover(state: OmpDiscoverState | undefined): void {
		this.#discover = state;
		if (state) {
			this.#mode = "discover";
			this.#discoverSelected = Math.max(0, Math.min(this.#discoverSelected, state.rows.length - 1));
		} else if (this.#mode === "discover") {
			this.#mode = "list";
		}
		this.#changed();
		this.#host.requestRender();
	}

	showViewer(title: string, rows: string[], choose?: (index: number) => void): void {
		this.#viewer = { title, rows, selected: 0, choose };
		this.#changed();
		this.#host.requestRender();
	}

	handleInput(data: string): void {
		const viewer = this.#viewer;
		if (viewer) {
			if (matchesKey(data, "escape")) this.#viewer = undefined;
			else if (matchesKey(data, "enter")) {
				this.#viewer = undefined;
				viewer.choose?.(viewer.selected);
			} else
				viewer.selected = Math.max(
					0,
					Math.min(
						viewer.rows.length - 1,
						viewer.selected + navigationDelta(data, OMP_DETAIL_WINDOW),
					),
				);
			this.#changed();
			this.#host.requestRender();
			return;
		}
		if (this.#prompt) {
			this.#promptKey(data);
			return;
		}
		if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) {
			if (this.#mode === "discover") this.setDiscover(undefined);
			else this.#host.onBlur();
			return;
		}
		if (this.#mode === "discover") {
			this.#discoverKey(data);
			return;
		}
		const delta = navigationDelta(
			data,
			this.#mode === "detail" ? OMP_DETAIL_WINDOW : OMP_PANEL_WINDOW,
		);
		if (delta !== 0) {
			if (this.#mode === "detail") this.#detailScroll = Math.max(0, this.#detailScroll + delta);
			else this.#select(this.#selected + delta);
			this.#changed();
			this.#host.requestRender();
			return;
		}
		if (matchesKey(data, "enter")) {
			if (this.#mode === "list" && !this.selected) return;
			this.#mode = this.#mode === "list" ? "detail" : "list";
			this.#detailScroll = 0;
			this.#changed();
			this.#host.requestRender();
			return;
		}
		switch (data) {
			case "a":
			case "n": {
				const session = this.selected;
				const approval = session?.pendingApprovals[this.#approvalSelected];
				if (session && approval)
					this.#host.onApproval?.(session, approval.id, data === "a" ? "approve_once" : "deny");
				return;
			}
			case "[":
			case "]":
				this.#approvalSelected = Math.max(
					0,
					Math.min(
						(this.selected?.pendingApprovals.length ?? 1) - 1,
						this.#approvalSelected + (data === "[" ? -1 : 1),
					),
				);
				this.#changed();
				this.#host.requestRender();
				return;
			case "{":
			case "}":
				this.#subagentSelected = Math.max(
					0,
					Math.min(
						(this.selected?.subagents.length ?? 1) - 1,
						this.#subagentSelected + (data === "{" ? -1 : 1),
					),
				);
				this.#changed();
				this.#host.requestRender();
				return;
			case "v": {
				const session = this.selected;
				const id = session?.subagents[this.#subagentSelected]?.id;
				if (session && id) this.#host.onSubagent?.(session, id);
				return;
			}
			case "m":
				if (this.selected) this.#host.onConfigure?.(this.selected);
				return;
			case "r":
				this.#host.onRefresh();
				return;
			case "d":
				this.#host.onDiscover();
				return;
			case "s":
			case "f":
			case "R":
				this.#openPrompt(data === "s" ? "steer" : data === "R" ? "redirect" : "followUp");
				return;
			case "c":
			case "x": {
				const session = this.#actionable(data === "c" ? "cancel" : "close");
				if (!session) return;
				if (data === "c") this.#host.onCancel(session);
				else this.#host.onClose(session);
				return;
			}
		}
	}

	invalidate(): void {
		// Nothing cached in row form: theme, focus and elapsed time are read at render time.
	}

	#operatorRows(session: OmpSession): string[] {
		const rows = [
			`approval mode ${session.approvalMode ?? "unknown"} · approved ${session.approvals.approved} · denied ${session.approvals.denied} · expired ${session.approvals.expired}`,
		];
		for (const [index, approval] of session.pendingApprovals.entries())
			rows.push(
				`${index === this.#approvalSelected ? "▸" : " "} approval ${approval.id} · ${approval.tool ?? "tool"} · ${typeof approval.details === "string" ? approval.details : JSON.stringify(approval.details)}`,
			);
		if (session.worktree) {
			const tree = session.worktree;
			rows.push(
				`worktree ${tree.path ?? "unknown"} · ${tree.branch ?? "unknown"}`,
				`kept ${tree.kept ?? "unknown"} · dirty ${tree.dirty ?? "unknown"} · commits ${tree.commits ?? "unknown"}`,
				`merge hint: review, then merge ${tree.branch ?? "worktree branch"} into ${tree.base ?? "base branch"}`,
			);
		}
		for (const [index, agent] of session.subagents.entries())
			rows.push(
				`${index === this.#subagentSelected ? "▸" : " "} subagent ${agent.id ?? "?"} · ${agent.status ?? "unknown"} · ${agent.activity ?? agent.description ?? ""}`,
			);
		return rows;
	}

	// -- input -----------------------------------------------------------------

	#select(index: number): void {
		this.#selected = Math.max(0, Math.min(this.#sessions.length - 1, index));
		this.#selectedId = this.#sessions[this.#selected]?.id;
	}

	/** The selected session when it still has a process to act on; otherwise says why not. */
	#actionable(verb: string): OmpSession | undefined {
		const session = this.selected;
		if (!session) {
			this.setFlash({ text: `no omp session to ${verb}`, level: "warning" });
			return undefined;
		}
		if (isOmpSessionEnded(session)) {
			this.setFlash({
				text: `${session.id} has ended — press d to find and resume it`,
				level: "warning",
			});
			return undefined;
		}
		return session;
	}

	#openPrompt(mode: OmpSendMode): void {
		const session = this.#actionable(mode === "steer" ? "steer" : "follow up");
		if (!session) return;
		this.#prompt = { mode, sessionId: session.id, text: "", sending: false };
		this.#changed();
		this.#host.requestRender();
	}

	/** While the field is open it owns the keyboard, as the switcher's inline prompt does. */
	#promptKey(data: string): void {
		const prompt = this.#prompt;
		if (!prompt) return;
		if (prompt.sending) return;
		if (matchesKey(data, "escape")) {
			this.#prompt = undefined;
		} else if (matchesKey(data, "enter")) {
			void this.#submitPrompt(prompt);
			return;
		} else if (matchesKey(data, "backspace")) {
			prompt.text = prompt.text.slice(0, -1);
		} else if (matchesKey(data, "ctrl+u")) {
			prompt.text = "";
		} else if (isPrintable(data)) {
			prompt.text += data;
		} else {
			return;
		}
		this.#changed();
		this.#host.requestRender();
	}

	async #submitPrompt(prompt: PromptState): Promise<void> {
		const message = prompt.text.trim();
		const session = this.#sessions.find((candidate) => candidate.id === prompt.sessionId);
		if (!message || !session) {
			if (!session) this.#prompt = undefined;
			this.#changed();
			this.#host.requestRender();
			return;
		}
		prompt.sending = true;
		this.#changed();
		this.#host.requestRender();
		const accepted = await this.#host.onSend(session, prompt.mode, message);
		// A refused or unacknowledged message stays in the field for review.
		prompt.sending = false;
		if (accepted && this.#prompt === prompt) this.#prompt = undefined;
		this.#changed();
		this.#host.requestRender();
	}

	#discoverKey(data: string): void {
		const rows = this.#discover?.rows ?? [];
		const delta = navigationDelta(data, OMP_PANEL_WINDOW);
		if (delta !== 0) {
			this.#discoverSelected = Math.max(
				0,
				Math.min(rows.length - 1, this.#discoverSelected + delta),
			);
		} else if (matchesKey(data, "enter")) {
			const row = this.selectedDiscovered;
			if (row) this.#host.onResume(row);
			return;
		} else if (data === "C") {
			const row = this.selectedDiscovered;
			if (row?.interrupted) this.#host.onContinue?.(row);
			return;
		} else if (data === "r") {
			this.#host.onDiscover();
			return;
		} else if (data === "d") {
			this.setDiscover(undefined);
			return;
		} else {
			return;
		}
		this.#changed();
		this.#host.requestRender();
	}

	#changed(): void {
		this.#revision += 1;
	}

	// -- native (TSP) --------------------------------------------------------------

	/** A card of `agent` nodes, the same kind the task tree and the omp tool card use. */
	describe(): NativeNode {
		if (!this.#visible) return EMPTY_NODE;
		if (this.#native?.revision === this.#revision) return this.#native.node;
		const now = this.#host.now?.() ?? Date.now();
		const body: NativeChild[] = [];
		if (this.#unavailable) {
			body.push(text([span(safeLine(this.#unavailable), "warning")], { key: "unavailable" }));
		}
		if (this.#viewer) {
			body.push(text([span(safeLine(this.#viewer.title), "strong")], { key: "viewer-title" }));
			for (const [index, line] of this.#viewer.rows.entries())
				body.push(
					text([span(`${index === this.#viewer.selected ? "▸ " : "  "}${safeLine(line)}`)], {
						key: `viewer:${index}`,
					}),
				);
		} else if (this.#mode === "discover") {
			body.push(...this.#discoverNodes(now));
		} else if (this.#mode === "detail" && this.selected) {
			const session = this.selected;
			body.push(ompAgentNode(session, { now, key: session.id, children: ompDetailNodes(session) }));
			for (const [index, line] of this.#operatorRows(session).entries())
				body.push(text([span(safeLine(line))], { key: `operator:${index}` }));
		} else if (this.#sessions.length === 0) {
			body.push(
				text([span("No omp sessions yet — /omp run <prompt> starts one.", "dim")], {
					key: "empty",
				}),
			);
		} else {
			for (const [index, session] of this.#sessions.entries()) {
				body.push(
					ompAgentNode(session, { now, key: session.id, selected: index === this.#selected }),
				);
			}
		}
		const prompt = this.#promptLine();
		if (prompt)
			body.push(text([span(prompt.label, "muted"), span(prompt.text)], { key: "prompt" }));
		if (this.#flash) {
			body.push(
				text([span(this.#flash.text, toneFor(this.#flash.level))], { wrap: "word", key: "flash" }),
			);
		}
		body.push(text([span(this.#hint(), "dim")], { key: "hint" }));
		const busy = this.#sessions.filter(isOmpSessionBusy).length;
		const described = card(
			{
				head: [span("omp", "strong"), span(` · ${this.#headline()}`, "muted")],
				status: busy > 0 ? "running" : "done",
			},
			body,
		);
		this.#native = { revision: this.#revision, node: described };
		return described;
	}

	#discoverNodes(now: number): NativeChild[] {
		const state = this.#discover;
		if (!state) return [];
		if (state.loading)
			return [text([span("Scanning omp session files…", "dim")], { key: "loading" })];
		if (state.error) {
			return [
				text([span(`discover failed: ${state.error}`, "error")], { wrap: "word", key: "error" }),
			];
		}
		if (state.rows.length === 0) {
			return [text([span("No omp sessions recorded for this directory.", "dim")], { key: "none" })];
		}
		return state.rows.map((row, index) =>
			text(
				[
					span(index === this.#discoverSelected ? "▸ " : "  ", "accent"),
					span(safeLine(row.title, 80) || "(untitled)"),
					span(` · ${discoveredFacts(row, now)}`, "muted"),
				],
				{ key: `d:${row.ompSessionId}` },
			),
		);
	}

	// -- rows ------------------------------------------------------------------

	render(width: number): readonly string[] {
		if (!this.#visible || width <= 0) return EMPTY;
		const theme = getTheme();
		const clamp = (line: string) => truncateToWidth(line, width);
		const lines = [theme.fg("accent", clamp(`omp · ${this.#headline()}`))];
		if (this.#unavailable) lines.push(theme.fg("warning", clamp(safeLine(this.#unavailable))));
		const now = this.#host.now?.() ?? Date.now();
		if (this.#viewer) {
			const start = Math.max(0, this.#viewer.selected - OMP_DETAIL_WINDOW + 1);
			return [
				...lines,
				clamp(safeLine(this.#viewer.title)),
				...this.#viewer.rows
					.slice(start, start + OMP_DETAIL_WINDOW)
					.map((line, index) =>
						clamp(`${start + index === this.#viewer!.selected ? "▸ " : "  "}${safeLine(line)}`),
					),
				"↑↓ select/scroll · enter choose/back · esc back",
			];
		}
		if (this.#mode === "discover") lines.push(...this.#discoverRows(now, clamp));
		else if (this.#mode === "detail" && this.selected)
			lines.push(...this.#detailRows(this.selected, now, clamp));
		else lines.push(...this.#listRows(now, clamp));
		const prompt = this.#promptLine();
		if (prompt) {
			const cursor = prompt.sending ? "" : "▏";
			lines.push(clamp(`${theme.fg("muted", prompt.label)}${prompt.text}${cursor}`));
		}
		if (this.#flash) lines.push(theme.fg(slotFor(this.#flash.level), clamp(this.#flash.text)));
		if (this.focused) lines.push(theme.fg("dim", clamp(this.#hint())));
		return lines;
	}

	#listRows(now: number, clamp: (line: string) => string): string[] {
		const theme = getTheme();
		if (this.#sessions.length === 0) {
			return [theme.fg("dim", clamp("No omp sessions yet — /omp run <prompt> starts one."))];
		}
		const start = Math.max(
			0,
			Math.min(this.#selected - OMP_PANEL_WINDOW + 1, this.#sessions.length - OMP_PANEL_WINDOW),
		);
		const end = Math.min(start + OMP_PANEL_WINDOW, this.#sessions.length);
		const lines: string[] = [];
		for (let index = start; index < end; index++) {
			const session = this.#sessions[index]!;
			const selected = index === this.#selected;
			const marker = selected && this.focused ? theme.cursor : " ";
			const elapsed = ompElapsedMs(session, now);
			const facts = [
				ompStatusText(session),
				session.cwd ? safeLine(basename(session.cwd), 30) : undefined,
				session.model ? safeLine(session.model, 40) : undefined,
				session.activity ? safeLine(session.activity, 80) : undefined,
				elapsed !== undefined ? formatElapsed(elapsed) : undefined,
				ompUsageText(session),
			].filter(Boolean);
			const row = `${marker} ${OMP_STATUS_GLYPHS[session.status]} ${ompSessionLabel(session)} · ${facts.join(" · ")}`;
			lines.push(theme.fg(selected && this.focused ? "accent" : statusSlot(session), clamp(row)));
		}
		const hidden = this.#sessions.length - (end - start);
		if (hidden > 0) lines.push(theme.fg("dim", clamp(`  …${hidden} more · ↑↓ browse`)));
		return lines;
	}

	#detailRows(session: OmpSession, now: number, clamp: (line: string) => string): string[] {
		const theme = getTheme();
		const elapsed = ompElapsedMs(session, now);
		const rows: Array<[ColorSlot, string]> = [
			[
				statusSlot(session),
				`${OMP_STATUS_GLYPHS[session.status]} ${ompStatusText(session)}${elapsed !== undefined ? ` · ${formatElapsed(elapsed)}` : ""} · ${session.turns} turns · ${session.toolCalls} tools`,
			],
		];
		for (const line of this.#operatorRows(session)) rows.push(["text", safeLine(line)]);
		const facts = [
			session.cwd ? `cwd ${safeLine(session.cwd, 120)}` : undefined,
			session.model
				? `model ${safeLine(session.model, 60)}${session.thinking ? ` (${safeLine(session.thinking, 20)})` : ""}`
				: undefined,
			session.ompSessionId ? `omp ${safeLine(session.ompSessionId, 40)}` : undefined,
		].filter(Boolean);
		if (facts.length > 0) rows.push(["muted", facts.join(" · ")]);
		const usage = ompUsageText(session);
		if (usage) rows.push(["muted", `usage ${usage}`]);
		if (session.activity) rows.push(["text", `activity ${safeLine(session.activity)}`]);
		for (const tool of session.activeTools) {
			rows.push([
				"toolRunning",
				`  ▶ ${safeLine(tool.name, 40)}${tool.intent ? ` — ${safeLine(tool.intent, 120)}` : ""}`,
			]);
		}
		if (session.recentTools.length > 0) rows.push(["muted", "recent tools"]);
		for (const tool of session.recentTools) {
			const took = tool.durationMs != null ? ` ${Math.round(tool.durationMs)}ms` : "";
			rows.push([
				tool.isError ? "error" : "dim",
				`  ${tool.isError ? "✗" : "✓"} ${safeLine(tool.name, 40)}${took}${tool.intent ? ` — ${safeLine(tool.intent, 120)}` : ""}`,
			]);
		}
		const progress = ompTodoProgress(session.todos);
		if (progress) rows.push(["muted", `todos ${progress}`]);
		for (const todo of session.todos) {
			const mark = (Object.hasOwn(TODO_MARKS, todo.status) && TODO_MARKS[todo.status]) || "[ ]";
			const phase = todo.phase ? `${safeLine(todo.phase, 30)}: ` : "";
			rows.push([
				todo.status === "in_progress" ? "accent" : "text",
				`  ${mark} ${phase}${safeLine(todo.content)}`,
			]);
		}
		if (session.subagents.length > 0) rows.push(["muted", "subagents"]);
		for (const agent of session.subagents) {
			const label = [agent.agent, agent.id]
				.filter(Boolean)
				.map((part) => safeLine(part ?? "", 40))
				.join(" ");
			rows.push([
				"text",
				`  ${safeLine(agent.status ?? "?", 20)} ${label}${agent.description ? ` — ${safeLine(agent.description, 120)}` : ""}`,
			]);
		}
		if (session.declinedPrompts > 0) {
			rows.push([
				"warning",
				`${session.declinedPrompts} interactive omp prompt(s) declined (headless)`,
			]);
		}
		if (session.error) rows.push(["error", `error ${safeLine(session.error)}`]);
		const words = session.result ?? session.lastText;
		if (words) {
			rows.push(["muted", session.result ? "result" : "latest"]);
			for (const line of safeText(words).trim().split("\n")) rows.push(["text", `  ${line}`]);
		}
		if (session.exit) {
			rows.push([
				"dim",
				`exit ${session.exit.code ?? "?"}${session.exit.reason ? ` (${safeLine(session.exit.reason, 40)})` : ""}`,
			]);
		}
		const maxScroll = Math.max(0, rows.length - OMP_DETAIL_WINDOW);
		this.#detailScroll = Math.min(this.#detailScroll, maxScroll);
		const visible = rows.slice(this.#detailScroll, this.#detailScroll + OMP_DETAIL_WINDOW);
		const lines = visible.map(([slot, line]) => theme.fg(slot, clamp(line)));
		const below = rows.length - this.#detailScroll - visible.length;
		if (this.#detailScroll > 0 || below > 0) {
			lines.push(
				theme.fg("dim", clamp(`  ${this.#detailScroll} above · ${below} below · ↑↓ scroll`)),
			);
		}
		return lines;
	}

	#discoverRows(now: number, clamp: (line: string) => string): string[] {
		const theme = getTheme();
		const state = this.#discover;
		if (!state) return [];
		if (state.loading) return [theme.fg("dim", clamp("scanning omp session files…"))];
		if (state.error) return [theme.fg("error", clamp(`discover failed: ${state.error}`))];
		if (state.rows.length === 0) {
			return [theme.fg("dim", clamp("no omp sessions recorded for this directory"))];
		}
		const start = Math.max(
			0,
			Math.min(this.#discoverSelected - OMP_PANEL_WINDOW + 1, state.rows.length - OMP_PANEL_WINDOW),
		);
		const end = Math.min(start + OMP_PANEL_WINDOW, state.rows.length);
		const lines: string[] = [];
		for (let index = start; index < end; index++) {
			const row = state.rows[index]!;
			const selected = index === this.#discoverSelected;
			const marker = selected && this.focused ? theme.cursor : " ";
			const line = `${marker} ${safeLine(row.title, 80) || "(untitled)"} · ${discoveredFacts(row, now)}`;
			lines.push(theme.fg(selected && this.focused ? "accent" : "text", clamp(line)));
		}
		const hidden = state.rows.length - (end - start);
		if (hidden > 0) lines.push(theme.fg("dim", clamp(`  …${hidden} more · ↑↓ browse`)));
		return lines;
	}

	// -- shared copy -------------------------------------------------------------

	#headline(): string {
		if (this.#mode === "discover") {
			const state = this.#discover;
			const where = state ? safeLine(basename(state.cwd) || state.cwd, 40) : "";
			return `resume from ${where}${state && !state.loading ? ` · ${state.rows.length} found` : ""}`;
		}
		if (this.#mode === "detail" && this.selected) {
			return `${ompSessionLabel(this.selected)} (${this.selected.id})`;
		}
		const live = this.#sessions.filter((session) => !isOmpSessionEnded(session)).length;
		const busy = this.#sessions.filter(isOmpSessionBusy).length;
		return `${live} live · ${busy} running · ${this.#sessions.length - live} ended`;
	}

	#promptLine(): { label: string; text: string; sending: boolean } | undefined {
		const prompt = this.#prompt;
		if (!prompt) return undefined;
		const verb =
			prompt.mode === "steer" ? "steer" : prompt.mode === "redirect" ? "redirect" : "follow-up";
		return {
			label: `${verb} ${prompt.sessionId}${prompt.sending ? " (sending…)" : ""} › `,
			text: prompt.text,
			sending: prompt.sending,
		};
	}

	#hint(): string {
		if (this.#prompt) return "enter sends · esc cancels · ctrl+u clears";
		if (this.#mode === "discover")
			return "SOURCE · ↑↓ select · enter resumes · C continue interrupted · r rescan · esc back";
		const back = this.#mode === "detail" ? "enter list · ↑↓ scroll" : "↑↓ select · enter detail";
		return `${back} · s steer · f follow-up · R redirect · m model · [/] approval · a approve · n deny · {/} child · v transcript · c cancel · x close · r refresh · d resume · esc close`;
	}
}

const EMPTY: readonly string[] = Object.freeze([]);

const TODO_MARKS: Record<string, string> = {
	completed: "[x]",
	done: "[x]",
	in_progress: "[>]",
	abandoned: "[-]",
	blocked: "[!]",
};

function navigationDelta(data: string, page: number): number {
	if (matchesKey(data, "up") || matchesKey(data, "ctrl+p")) return -1;
	if (matchesKey(data, "down") || matchesKey(data, "ctrl+n")) return 1;
	if (matchesKey(data, "pageUp")) return -page;
	if (matchesKey(data, "pageDown")) return page;
	return 0;
}

/** `12s`, `4m07s`, `2h05m`: the task tree's terse elapsed form. */
export function formatElapsed(ms: number): string {
	const seconds = Math.floor(ms / 1000);
	if (seconds < 60) return `${seconds}s`;
	const minutes = Math.floor(seconds / 60);
	if (minutes < 60) return `${minutes}m${String(seconds % 60).padStart(2, "0")}s`;
	return `${Math.floor(minutes / 60)}h${String(minutes % 60).padStart(2, "0")}m`;
}

function discoveredFacts(row: OmpDiscoveredSession, now: number): string {
	const updated = row.updatedAt ?? row.createdAt;
	return [
		`SOURCE ${row.source ?? "unknown"}`,
		row.interrupted ? "⚠ interrupted" : undefined,
		row.worktree?.branch ? `worktree ${safeLine(row.worktree.branch)}` : undefined,
		safeLine(row.lastStatus, 20),
		updated != null ? `${formatElapsed(Math.max(0, now - updated))} ago` : undefined,
		row.model ? safeLine(row.model, 40) : undefined,
		row.liveId ? `live ${row.liveId}` : undefined,
		row.activeElsewhere ? "active elsewhere" : undefined,
		safeLine(row.ompSessionId, 13),
	]
		.filter(Boolean)
		.join(" · ");
}

function statusSlot(session: OmpSession): ColorSlot {
	if (session.status === "failed" || session.lastTurn === "error") return "error";
	if (isOmpSessionBusy(session)) return "toolRunning";
	if (isOmpSessionEnded(session)) return "dim";
	return "text";
}

function slotFor(level: NoticeLevel): ColorSlot {
	return level === "error" ? "error" : level === "warning" ? "warning" : "muted";
}

function toneFor(level: NoticeLevel): string {
	return level === "error" ? "error" : level === "warning" ? "warning" : "muted";
}
