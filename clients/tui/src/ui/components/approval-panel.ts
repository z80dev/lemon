/**
 * The approval dialog.
 *
 * A tool is waiting on a yes or no, so this panel takes the keyboard: the
 * decision is the only thing the user can usefully do next, and an editor that
 * still swallowed keystrokes would let them type a prompt into a client that
 * cannot send it. Esc denies rather than dismissing — a dialog you can close
 * without answering is a dialog that silently blocks the agent forever.
 *
 * The command is **wrapped, never truncated**. Truncating the one string the
 * decision is about ("run `rm -rf …`") is how a user approves something they
 * did not read; a long command costs rows instead, capped at
 * {@link ACTION_PREVIEW_ROWS} with the remainder counted.
 *
 * Like the queue panel this lives below the transcript, inside the repaintable
 * region, so its countdown can tick without touching committed scrollback.
 */

import { type KeyId, matchesKey } from "@oh-my-pi/pi-tui/keys";
import { col, EMPTY_NODE, node, span, text } from "@oh-my-pi/pi-tui/native/describe";
import type { NativeNode, NativeUiEvent } from "@oh-my-pi/pi-tui/native/node";
import { actionBar, actionButton } from "@oh-my-pi/pi-tui/native/overlay";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth, visibleWidth, wrapTextWithAnsi } from "@oh-my-pi/pi-tui/utils";
import { type ApprovalRequestedEvent, PROPOSE_PLAN_TOOL } from "../../protocol/types.ts";
import { getTheme } from "../theme/theme.ts";
import { WidthClamp } from "./width-safe.ts";

/** Rows of command preview before the remainder is folded into a counter. */
export const ACTION_PREVIEW_ROWS = 10;

export interface ApprovalOption {
	/** The quick-pick digit. */
	key: KeyId;
	label: string;
	/** Verbatim `exec.approval.resolve` decision — snake_case is the daemon's. */
	decision: string;
}

export const APPROVAL_OPTIONS: readonly ApprovalOption[] = [
	{ key: "1", label: "allow once", decision: "approve_once" },
	{ key: "2", label: "allow for this session", decision: "approve_session" },
	{ key: "3", label: "allow always", decision: "approve_global" },
	{ key: "4", label: "deny", decision: "deny" },
];

/** Rows of plan Markdown shown before the rest is counted. */
export const PLAN_PREVIEW_ROWS = 12;

/**
 * A plan proposal is either executed now or sent back; a session/agent/global
 * scope would pre-approve plans nobody has read yet, so none is offered.
 */
export const PLAN_OPTIONS: readonly ApprovalOption[] = [
	{ key: "1", label: "Approve and execute", decision: "approve_once" },
	{ key: "2", label: "Refine plan", decision: "deny" },
];

/** The choices a request offers: plan proposals get their own pair. */
export function approvalOptions(
	event: ApprovalRequestedEvent | undefined,
): readonly ApprovalOption[] {
	return event?.tool === PROPOSE_PLAN_TOOL ? PLAN_OPTIONS : APPROVAL_OPTIONS;
}

export interface ApprovalPanelOptions {
	/** A decision the user made here. */
	onDecide: (decision: string, event: ApprovalRequestedEvent) => void;
	/** Called when a key moved the selection and the row needs a repaint. */
	requestRender?: () => void;
	/** Clock seam for the countdown. */
	now?: () => number;
}

export class ApprovalPanelComponent implements Component {
	/** Written by `TUI.setFocus`. */
	focused = false;

	readonly #options: ApprovalPanelOptions;
	readonly #now: () => number;
	readonly #clamp = new WidthClamp();
	#event: ApprovalRequestedEvent | undefined;
	#selected = 0;
	/** Bumped by {@link tick} so the cached rows expire once a second. */
	#clockRevision = 0;

	#cachedRows: readonly string[] | undefined;
	#cachedWidth = -1;
	#cachedKey = "";
	#native: { event: ApprovalRequestedEvent; selected: number; node: NativeNode } | undefined;

	constructor(options: ApprovalPanelOptions) {
		this.#options = options;
		this.#now = options.now ?? Date.now;
	}

	get event(): ApprovalRequestedEvent | undefined {
		return this.#event;
	}

	get visible(): boolean {
		return this.#event !== undefined;
	}

	get selectedOption(): ApprovalOption {
		return approvalOptions(this.#event)[this.#selected]!;
	}

	/** Put a request on screen. A different request resets the selection. */
	show(event: ApprovalRequestedEvent): void {
		if (this.#event?.approvalId !== event.approvalId) this.#selected = 0;
		this.#event = event;
		this.#cachedRows = undefined;
	}

	hide(): void {
		this.#event = undefined;
		this.#cachedRows = undefined;
	}

	/** Re-read the clock. The host calls this about once a second. */
	tick(): void {
		if (!this.#event?.expiresAtMs) return;
		this.#clockRevision += 1;
		this.#cachedRows = undefined;
	}

	handleInput(data: string): void {
		const event = this.#event;
		if (!event) return;
		// Esc and Ctrl+C both deny: the request is blocking a tool either way, and
		// "I did not answer" is not one of the answers the daemon accepts.
		if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) {
			this.#options.onDecide("deny", event);
			return;
		}
		const quick = approvalOptions(event).find((option) => option.key === data);
		if (quick) {
			this.#options.onDecide(quick.decision, event);
			return;
		}
		if (matchesKey(data, "up") || matchesKey(data, "ctrl+p")) {
			this.#move(-1);
			return;
		}
		if (matchesKey(data, "down") || matchesKey(data, "ctrl+n")) {
			this.#move(1);
			return;
		}
		if (matchesKey(data, "enter")) {
			this.#options.onDecide(this.selectedOption.decision, event);
		}
	}

	invalidate(): void {
		this.#cachedRows = undefined;
		this.#clamp.reset();
	}

	render(width: number): readonly string[] {
		const key = this.#cacheKey();
		if (this.#cachedRows && this.#cachedWidth === width && this.#cachedKey === key) {
			return this.#cachedRows;
		}
		// The box costs four columns of chrome that cannot themselves be wrapped,
		// so a terminal narrower than the border is the one case the built rows can
		// still overflow; the clamp is what keeps the render contract absolute.
		const rows = this.#clamp.apply(this.#build(width), width);
		this.#cachedRows = rows;
		this.#cachedWidth = width;
		this.#cachedKey = key;
		return rows;
	}

	/**
	 * omp's approval prompt in the composer's place (an `omp.editor.ask.*`
	 * root, so Tern sizes it to the composer column): the title, the exact
	 * action — every line, wrapped, never clipped — the rationale and session,
	 * then the decisions as `omp.btn` buttons in an `omp.actions` bar with the
	 * expiry counting down terminal-side. A click takes the quick-pick digit's
	 * path; the keyboard selection is the accented button. A plan proposal shows
	 * its plan file and a bounded Markdown preview instead of the action, and
	 * only its two decisions.
	 */
	describe(): NativeNode {
		const event = this.#event;
		if (!event) return EMPTY_NODE;
		const cached = this.#native;
		if (cached?.event === event && cached.selected === this.#selected) return cached.node;
		const plan = event.tool === PROPOSE_PLAN_TOOL;
		const securityOverride = !plan && event.action?.security_override === true;
		const path = plan && typeof event.action?.path === "string" ? event.action.path : "";
		const details = plan
			? [
					...(path ? [`plan file: ${path}`] : []),
					...planPreviewRows(typeof event.action?.plan === "string" ? event.action.plan : ""),
				]
			: describeAction(event.action).split("\n");
		const children: NativeNode[] = [
			node(
				"text",
				{
					text: plan
						? planTitle(event.action)
						: `${securityOverride ? "Security override" : "Approval required"} · ${event.tool ?? "tool"}`,
					role: "omp.approval.title",
					tone: plan ? "accent" : securityOverride ? "error" : "warning",
				},
				undefined,
				"title",
			),
			node(
				"col",
				{ role: "omp.approval.details" },
				details.map((line, index) =>
					node(
						"text",
						plan && path && index === 0
							? { spans: [span(line, "muted")], wrap: "word" }
							: { text: line, wrap: "word" },
						undefined,
						String(index),
					),
				),
				"details",
			),
		];
		if (event.rationale) {
			children.push(text([span(event.rationale, "muted")], { wrap: "word", key: "rationale" }));
		}
		if (event.sessionKey) {
			children.push(text([span(event.sessionKey, "dim")], { truncate: "end", key: "session" }));
		}
		const buttons = approvalOptions(event).map((option, index) =>
			actionButton(
				(securityOverride ? securityOverrideLabel(option) : option.label).replace(/^./, (first) =>
					first.toUpperCase(),
				),
				option.decision,
				{
					keys: option.key,
					// Refining a plan is a normal answer, not a refusal.
					...(option.decision === "deny" && !plan
						? { tone: "error" as const }
						: index === this.#selected
							? { tone: "accent" as const }
							: {}),
				},
			),
		);
		const countdown = event.expiresAtMs
			? node(
					"elapsed",
					{ age: Math.min(0, this.#now() - event.expiresAtMs), format: "short" },
					undefined,
					"expires",
				)
			: undefined;
		children.push(actionBar([...(countdown ? [countdown] : []), null, ...buttons]));
		const described = col(children, { role: "omp.editor.ask.approval", gap: "md" });
		this.#native = { event, selected: this.#selected, node: described };
		return described;
	}

	/** A decision button: the same resolve path as its quick-pick digit. */
	handleNativeEvent(event: NativeUiEvent): void {
		const pending = this.#event;
		if (!pending || event.type !== "action") return;
		const option = approvalOptions(pending).find((candidate) => candidate.decision === event.act);
		if (option) this.#options.onDecide(option.decision, pending);
	}

	// -- internals -----------------------------------------------------------

	#move(direction: -1 | 1): void {
		const next = this.#selected + direction;
		if (next < 0 || next >= approvalOptions(this.#event).length) return;
		this.#selected = next;
		this.#cachedRows = undefined;
		this.#options.requestRender?.();
	}

	#cacheKey(): string {
		return [this.#event?.approvalId ?? "-", this.#selected, this.#clockRevision].join("|");
	}

	#build(width: number): readonly string[] {
		const event = this.#event;
		if (!event) return EMPTY;
		const theme = getTheme();
		const box = theme.boxRound;
		// Border + one space of padding on each side.
		const inner = Math.max(1, width - 4);
		const rows: string[] = [];

		const line = (plain: string, styled?: string) => {
			const pad = " ".repeat(Math.max(0, inner - visibleWidth(plain)));
			rows.push(
				`${theme.fg("borderMuted", box.vertical)} ${styled ?? plain}${pad} ${theme.fg("borderMuted", box.vertical)}`,
			);
		};

		rows.push(
			theme.fg(
				"warning",
				`${box.topLeft}${box.horizontal.repeat(Math.max(0, width - 2))}${box.topRight}`,
			),
		);

		const plan = event.tool === PROPOSE_PLAN_TOOL;
		const securityOverride = !plan && event.action?.security_override === true;
		const title = truncateToWidth(
			plan
				? planTitle(event.action)
				: `${securityOverride ? "SECURITY OVERRIDE" : "approval required"} · ${event.tool ?? "tool"}`,
			inner,
		);
		line(title, theme.fg(plan ? "accent" : "warning", title));

		if (plan) {
			const path = typeof event.action?.path === "string" ? event.action.path : "";
			if (path) {
				for (const row of wrapTextWithAnsi(`plan file: ${path}`, inner)) {
					line(row, theme.fg("muted", row));
				}
			}
			const markdown = typeof event.action?.plan === "string" ? event.action.plan : "";
			for (const row of planPreviewRows(markdown, inner)) line(row, theme.fg("text", row));
		} else {
			for (const row of previewRows(describeAction(event.action), inner)) {
				line(row, theme.fg("text", row));
			}
		}

		if (event.rationale) {
			for (const row of wrapTextWithAnsi(event.rationale, inner).slice(0, 3)) {
				line(row, theme.fg("muted", row));
			}
		}

		const meta = [event.sessionKey, countdown(event.expiresAtMs, this.#now())]
			.filter(Boolean)
			.join(" · ");
		if (meta) {
			const clamped = truncateToWidth(meta, inner);
			line(clamped, theme.fg("dim", clamped));
		}

		const options = approvalOptions(event);
		for (const [index, option] of options.entries()) {
			const marker = index === this.#selected ? theme.cursor : " ";
			const label = securityOverride ? securityOverrideLabel(option) : option.label;
			const text = truncateToWidth(`${marker} ${option.key}  ${label}`, inner);
			line(
				text,
				index === this.#selected
					? theme.fg("accent", text)
					: theme.fg(option.decision === "deny" && !plan ? "error" : "text", text),
			);
		}

		const hint = truncateToWidth(
			`1-${options.length} picks · ↑↓ then enter · esc ${plan ? "refines" : "denies"}`,
			inner,
		);
		line(hint, theme.fg("dim", hint));
		rows.push(
			theme.fg(
				"borderMuted",
				`${box.bottomLeft}${box.horizontal.repeat(Math.max(0, width - 2))}${box.bottomRight}`,
			),
		);
		return rows;
	}
}

function securityOverrideLabel(option: ApprovalOption): string {
	switch (option.decision) {
		case "approve_once":
			return "accept this blocked bundle once";
		case "approve_session":
			return "accept this exact bundle for session";
		case "approve_global":
			return "accept this exact bundle always";
		default:
			return option.label;
	}
}

const EMPTY: readonly string[] = Object.freeze([]);

/**
 * The transcript's record of an approval — one line, in the scrollback, saying
 * what was asked and what was answered.
 *
 * It implements the FinalizableBlock protocol because it mutates *after* being
 * appended: a pending request stays unfinalized (so the container keeps it in
 * the repaintable live region and commits nothing), and answering it both bumps
 * the version and seals the block, at which point its final bytes may reach
 * native scrollback. Sealing on resolve is what stops an unanswered request
 * from pinning the commit seam open for the rest of the session.
 */
export class ApprovalRecordComponent implements Component {
	readonly #approvalId: string;
	readonly #tool: string | undefined;
	#decision: string | undefined;
	#finalized = false;
	#version = 0;

	#cachedRows: readonly string[] | undefined;
	#cachedWidth = -1;
	#cachedVersion = -1;
	#native: { version: number; node: NativeNode } | undefined;

	constructor(approvalId: string, tool: string | undefined, decision?: string) {
		this.#approvalId = approvalId;
		this.#tool = tool;
		if (decision) this.annotate(decision);
	}

	get decision(): string | undefined {
		return this.#decision;
	}

	/** Record the answer and seal the block. Idempotent. */
	annotate(decision: string): void {
		if (this.#finalized) return;
		this.#decision = decision;
		this.#finalized = true;
		this.#version += 1;
		this.#cachedRows = undefined;
	}

	invalidate(): void {
		this.#cachedRows = undefined;
	}

	render(width: number): readonly string[] {
		if (this.#cachedRows && this.#cachedWidth === width && this.#cachedVersion === this.#version) {
			return this.#cachedRows;
		}
		const theme = getTheme();
		const tool = this.#tool ?? "tool";
		const plan = this.#tool === PROPOSE_PLAN_TOOL;
		const { text, tone } = recordLine(this.#approvalId, tool, plan, this.#decision);
		const rows = [theme.fg(tone, truncateToWidth(` · ${text}`, width))];
		this.#cachedRows = rows;
		this.#cachedWidth = width;
		this.#cachedVersion = this.#version;
		return rows;
	}

	/** An `omp.notice` line toned by the outcome; it never offers a decision. */
	describe(): NativeNode {
		if (this.#native?.version === this.#version) return this.#native.node;
		const tool = this.#tool ?? "tool";
		const plan = this.#tool === PROPOSE_PLAN_TOOL;
		const { text, tone } = recordLine(this.#approvalId, tool, plan, this.#decision);
		// A pending request keeps its short native line; the id belongs to the plain rows.
		const line =
			this.#decision === undefined && !plan
				? `Approval requested for ${tool}`
				: text.replace(/^./, (first) => first.toUpperCase());
		const described = node("text", {
			spans: [span(line, tone)],
			wrap: "word",
			role: "omp.notice",
			tone,
		});
		this.#native = { version: this.#version, node: described };
		return described;
	}

	// -- FinalizableBlock ----------------------------------------------------

	isTranscriptBlockFinalized(): boolean {
		return this.#finalized;
	}

	getTranscriptBlockVersion(): number {
		return this.#version;
	}
}

/** `approve_session` -> `session`; the daemon's wire word minus its prefix. */
export function humanDecision(decision: string): string {
	return decision.startsWith("approve_") ? decision.slice("approve_".length) : decision;
}

/** True for an approving decision, in either the resolve (`approve_once`) or event (`once`) vocabulary. */
export function isApprovedDecision(decision: string | undefined): boolean {
	return (
		decision !== undefined &&
		(decision.startsWith("approve_") || ["once", "session", "global"].includes(decision))
	);
}

type RecordTone = "success" | "error" | "warning" | "muted";

/** The record's sentence (no leading bullet) and its tone for the current decision. */
function recordLine(
	approvalId: string,
	tool: string,
	plan: boolean,
	decision: string | undefined,
): { text: string; tone: RecordTone } {
	if (plan) {
		const text = planRecordText(approvalId, decision).replace(/^· /, "");
		if (decision === undefined) return { text, tone: "warning" };
		if (decision === "deny") return { text, tone: "muted" };
		return { text, tone: isApprovedDecision(decision) ? "success" : "warning" };
	}
	if (decision === undefined) {
		return { text: `approval requested for ${tool} (${approvalId})`, tone: "warning" };
	}
	if (isApprovedDecision(decision)) {
		return { text: `approval granted for ${tool} (${humanDecision(decision)})`, tone: "success" };
	}
	switch (decision) {
		case "deny":
			return { text: `approval denied for ${tool} (deny)`, tone: "error" };
		case "expired":
			return { text: `approval expired for ${tool} — the run ended`, tone: "warning" };
		case "timeout":
			return { text: `approval timed out for ${tool}`, tone: "warning" };
		case "cancelled":
			return { text: `approval withdrawn for ${tool}`, tone: "warning" };
		default:
			return { text: `approval closed for ${tool} (${decision})`, tone: "warning" };
	}
}

function planRecordText(approvalId: string, decision: string | undefined): string {
	if (decision === undefined) return `· plan proposed — awaiting your decision (${approvalId})`;
	if (decision === "deny") return "· plan sent back for refinement";
	if (isApprovedDecision(decision)) return "· plan approved — executing";
	if (decision === "expired") return "· plan proposal expired — the run ended";
	return `· plan proposal closed (${decision})`;
}

/** `Plan proposal · <title>`, the title flattened to one line. */
export function planTitle(action: Record<string, unknown> | undefined | null): string {
	const title = typeof action?.title === "string" ? action.title.replace(/\s+/g, " ").trim() : "";
	return `Plan proposal · ${title || "untitled plan"}`;
}

/**
 * The head of a proposed plan's Markdown, capped at {@link PLAN_PREVIEW_ROWS}
 * rows: wrapped to `width`, or source lines when the terminal wraps (the
 * native surface). What does not fit is counted in source lines, the unit the
 * plan file itself is read in. Control bytes are dropped: the text is agent
 * output, and it is printed into the terminal verbatim otherwise.
 */
export function planPreviewRows(markdown: string, width?: number): string[] {
	// biome-ignore lint/suspicious/noControlCharactersInRegex: stripping them is the point.
	const clean = markdown.replace(/\t/g, "  ").replace(/[\x00-\x09\x0b-\x1f\x7f-\x9f]/g, "");
	const lines = clean.replace(/\s+$/, "").split("\n");
	if (lines.length === 1 && lines[0] === "") return ["(empty plan)"];
	const rows: string[] = [];
	let shown = 0;
	for (const source of lines) {
		const wrapped = width === undefined ? [source] : wrapTextWithAnsi(source, width);
		const room = PLAN_PREVIEW_ROWS - rows.length;
		rows.push(...(wrapped.length === 0 ? [""] : wrapped).slice(0, room));
		if (wrapped.length > room) break;
		shown += 1;
		if (rows.length >= PLAN_PREVIEW_ROWS) break;
	}
	if (shown < lines.length) {
		const rest = lines.length - shown;
		rows.push(`… ${rest} more line${rest === 1 ? "" : "s"} (${lines.length} total)`);
	}
	return rows;
}

/**
 * Wrap the action text and cap it. The cap is on *rows*, not characters, so a
 * long single-line command still shows its first ten wrapped lines in full.
 */
export function previewRows(text: string, width: number): string[] {
	const wrapped = text.split("\n").flatMap((line) => wrapTextWithAnsi(line, width));
	if (wrapped.length <= ACTION_PREVIEW_ROWS) return wrapped;
	const kept = wrapped.slice(0, ACTION_PREVIEW_ROWS);
	kept.push(`+${wrapped.length - ACTION_PREVIEW_ROWS} more`);
	return kept;
}

/**
 * The human-readable thing being approved. Mirrors the daemon's own formatter
 * (`LemonChannels.Adapters.Telegram.Transport.ApprovalRequest.format_action/1`):
 * a command if there is one, otherwise the map, so no request is unreadable.
 */
export function describeAction(action: Record<string, unknown> | undefined | null): string {
	if (!action) return "(no action detail)";
	if (action.security_override === true) {
		const description =
			typeof action.description === "string" && action.description.trim().length > 0
				? action.description
				: "Override blocked security audit";
		const bundle =
			typeof action.bundle_hash === "string" && action.bundle_hash.length > 0
				? `bundle: ${action.bundle_hash}`
				: "bundle: unknown";
		const findings = Array.isArray(action.findings)
			? action.findings.filter((finding): finding is string => typeof finding === "string")
			: [];
		return [description, bundle, ...findings.map((finding) => `finding: ${finding}`)].join("\n");
	}
	for (const key of ["command", "cmd", "script", "path", "url", "description"]) {
		const value = action[key];
		if (typeof value === "string" && value.trim().length > 0) return value;
	}
	try {
		const json = JSON.stringify(action);
		return json && json !== "{}" ? json : "(no action detail)";
	} catch {
		return String(action);
	}
}

/** `expires in 42s` / `expires in 2m05s`, or nothing when there is no deadline. */
export function countdown(expiresAtMs: number | null | undefined, nowMs: number): string {
	if (!expiresAtMs) return "";
	const remaining = Math.round((expiresAtMs - nowMs) / 1000);
	if (remaining <= 0) return "expired";
	if (remaining < 60) return `expires in ${remaining}s`;
	const minutes = Math.floor(remaining / 60);
	return `expires in ${minutes}m${String(remaining % 60).padStart(2, "0")}s`;
}
