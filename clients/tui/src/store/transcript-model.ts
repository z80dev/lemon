/**
 * The transcript, as data.
 *
 * View-agnostic on purpose: this is what tests assert on and what a session
 * rebuild (P6 cold-session hydration) replays into components. Nothing here
 * imports pi-tui — a block knows what happened, not how it looks.
 */

import type { AgentAction, AgentActionKind } from "../protocol/types.ts";

export type BlockKind = "user" | "assistant" | "tool" | "approval" | "notice";

interface BlockBase {
	/** Unique within a session; stable for the block's lifetime. */
	id: string;
	kind: BlockKind;
	/** Wall-clock ms when the block was created. */
	at: number;
}

export interface UserBlock extends BlockBase {
	kind: "user";
	text: string;
}

export type AssistantStatus = "streaming" | "done" | "error" | "aborted";

export interface AssistantBlock extends BlockBase {
	kind: "assistant";
	runId: string;
	/** Full accumulated text. Never the server's truncated `completed.answer`. */
	text: string;
	status: AssistantStatus;
	/** Set when the run ended badly and the server had something to say. */
	error?: string;
}

export type ToolPhase = "started" | "updated" | "completed";

export interface ToolBlock extends BlockBase {
	kind: "tool";
	runId: string | undefined;
	/** `action.id` from the protocol; the upsert key. */
	actionId: string;
	toolKind: AgentActionKind | string;
	title: string;
	detail: Record<string, unknown> | undefined;
	phase: ToolPhase;
	ok: boolean | undefined;
	message: string | undefined;
}

export interface ApprovalBlock extends BlockBase {
	kind: "approval";
	approvalId: string;
	tool: string | undefined;
	status: "pending" | "resolved";
	decision?: string;
}

export type NoticeLevel = "info" | "warning" | "error";

export interface NoticeBlock extends BlockBase {
	kind: "notice";
	level: NoticeLevel;
	text: string;
}

export type Block = UserBlock | AssistantBlock | ToolBlock | ApprovalBlock | NoticeBlock;

let blockSeq = 0;

/** Monotonic block id. Prefixed by kind so transcripts read well in dumps. */
export function nextBlockId(kind: BlockKind): string {
	blockSeq += 1;
	return `${kind}-${blockSeq}`;
}

/** Test hook: make ids deterministic across cases. */
export function resetBlockIds(): void {
	blockSeq = 0;
}

/** Normalize a protocol phase string; anything unknown counts as an update. */
export function toToolPhase(phase: string | null | undefined): ToolPhase {
	return phase === "started" || phase === "completed" ? phase : "updated";
}

/** Best-effort human title for a tool action. */
export function toolTitle(action: AgentAction | undefined): string {
	const title = action?.title?.trim();
	if (title) return title;
	const kind = action?.kind?.trim();
	if (kind) return kind;
	return "tool";
}
