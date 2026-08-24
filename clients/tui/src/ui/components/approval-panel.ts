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

import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth, visibleWidth, wrapTextWithAnsi } from "@oh-my-pi/pi-tui/utils";
import type { ApprovalRequestedEvent } from "../../protocol/types.ts";
import { getTheme } from "../theme/theme.ts";
import { WidthClamp } from "./width-safe.ts";

/** Rows of command preview before the remainder is folded into a counter. */
export const ACTION_PREVIEW_ROWS = 10;

export interface ApprovalOption {
	/** The quick-pick digit. */
	key: string;
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
		return APPROVAL_OPTIONS[this.#selected]!;
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
		const quick = APPROVAL_OPTIONS.find((option) => option.key === data);
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

	// -- internals -----------------------------------------------------------

	#move(direction: -1 | 1): void {
		const next = this.#selected + direction;
		if (next < 0 || next >= APPROVAL_OPTIONS.length) return;
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

		const title = truncateToWidth(`approval required · ${event.tool ?? "tool"}`, inner);
		line(title, theme.fg("warning", title));

		for (const row of previewRows(describeAction(event.action), inner)) {
			line(row, theme.fg("text", row));
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

		for (const [index, option] of APPROVAL_OPTIONS.entries()) {
			const marker = index === this.#selected ? theme.cursor : " ";
			const text = truncateToWidth(`${marker} ${option.key}  ${option.label}`, inner);
			line(
				text,
				index === this.#selected
					? theme.fg("accent", text)
					: theme.fg(option.decision === "deny" ? "error" : "text", text),
			);
		}

		const hint = truncateToWidth("1-4 picks · ↑↓ then enter · esc denies", inner);
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
		const denied = this.#decision === "deny";
		const text = this.#decision
			? `· approval ${denied ? "denied" : "granted"} for ${tool} (${humanDecision(this.#decision)})`
			: `· approval requested for ${tool} (${this.#approvalId})`;
		const slot = this.#decision ? (denied ? "error" : "success") : "warning";
		const rows = [theme.fg(slot, truncateToWidth(` ${text}`, width))];
		this.#cachedRows = rows;
		this.#cachedWidth = width;
		this.#cachedVersion = this.#version;
		return rows;
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
