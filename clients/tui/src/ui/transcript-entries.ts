/**
 * Lemon transcript blocks as pi-tui replay entries.
 *
 * pi-tui's fullscreen transcript tools (`/copy` selector, rewind selector, link
 * browser) replay `TranscriptEntryLike`s through `ChatTranscriptBuilder`. Lemon
 * keeps its transcript as view-agnostic {@link Block}s, so this module is the one
 * adapter between them: each block becomes the entry (or entries) the builder
 * already knows how to draw, and {@link entryBlockId} maps any replayed entry id
 * back to the block it came from.
 *
 * Entry ids are derived from block ids, never invented: a block's own entry
 * carries the block id verbatim, and the one extra entry a tool block can emit
 * (its result) is `<blockId>:result`. Server journal ids are not known to the
 * client's blocks; commands that need them (rewind) resolve them from the
 * session tree against the blocks the entry ids lead back to.
 */

import type { TranscriptEntryLike } from "@oh-my-pi/pi-tui/chat/transcript-entry";
import type {
	ApprovalBlock,
	AssistantBlock,
	Block,
	NoticeBlock,
	ReasoningBlock,
	ToolBlock,
	UserBlock,
} from "../store/transcript-model.ts";
import { resolveToolName, toolArgs, toolDetails } from "./tool-view.ts";

/** Suffix of the synthetic tool-result entry that follows a tool block's call entry. */
export const RESULT_ENTRY_SUFFIX = ":result";

/** `customType` of an approval block's replayed message. */
export const APPROVAL_CUSTOM_TYPE = "lemon:approval";
/** `customType` of a notice block's replayed message. */
export const NOTICE_CUSTOM_TYPE = "lemon:notice";

/** Model name replayed assistant messages claim when the daemon reported none. */
const FALLBACK_MODEL = "lemon";

const ZERO_USAGE = {
	input: 0,
	output: 0,
	cacheRead: 0,
	cacheWrite: 0,
	totalTokens: 0,
	cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
} as const;

type MessageEntry = Extract<TranscriptEntryLike, { type: "message" }>;
type CustomEntry = Extract<TranscriptEntryLike, { type: "custom_message" }>;
type AssistantMessage = Extract<MessageEntry["message"], { role: "assistant" }>;
type UserContent = Extract<MessageEntry["message"], { role: "user" }>["content"];
type ImageContent = Extract<Exclude<UserContent, string>[number], { type: "image" }>;

/** The id of the block a replayed entry came from. */
export function entryBlockId(entryId: string): string {
	return entryId.endsWith(RESULT_ENTRY_SUFFIX)
		? entryId.slice(0, -RESULT_ENTRY_SUFFIX.length)
		: entryId;
}

/**
 * Convert blocks to entries `ChatTranscriptBuilder` replays: user prompts,
 * assistant text, reasoning as thinking, tools as a call plus (once finished)
 * its result, and approvals/notices as visible custom messages. Order is the
 * transcript's own; each entry's `parentId` is its predecessor.
 */
export function blocksToTranscriptEntries(blocks: readonly Block[]): TranscriptEntryLike[] {
	const entries: TranscriptEntryLike[] = [];
	let previous: string | null = null;
	const push = (entry: TranscriptEntryLike): void => {
		entries.push(entry);
		previous = entry.id;
	};
	for (const block of blocks) {
		const timestamp = isoTimestamp(block.at);
		switch (block.kind) {
			case "user":
				push(userEntry(block, previous, timestamp));
				break;
			case "assistant":
				push(assistantEntry(block, previous, timestamp));
				break;
			case "reasoning":
				// A reasoning block with no text yet draws nothing, so it is not an entry.
				if (block.text.trim()) push(reasoningEntry(block, previous, timestamp));
				break;
			case "tool": {
				push(toolCallEntry(block, previous, timestamp));
				const result = toolResultEntry(block, previous, timestamp);
				if (result) push(result);
				break;
			}
			case "approval":
				push(approvalEntry(block, previous, timestamp));
				break;
			case "notice":
				push(noticeEntry(block, previous, timestamp));
				break;
		}
	}
	return entries;
}

function isoTimestamp(at: number): string {
	const date = new Date(at);
	return Number.isNaN(date.getTime()) ? new Date(0).toISOString() : date.toISOString();
}

function userEntry(block: UserBlock, parentId: string | null, timestamp: string): MessageEntry {
	const sentAt = block.sentAt ?? block.at;
	const images: ImageContent[] = (block.images ?? []).map((image) => ({
		type: "image",
		data: image.data,
		mimeType: image.mime_type,
	}));
	const content: UserContent =
		images.length > 0 ? [{ type: "text", text: block.text }, ...images] : block.text;
	return {
		type: "message",
		id: block.id,
		parentId,
		timestamp,
		message: { role: "user", content, timestamp: sentAt },
	};
}

function assistantMessage(
	content: AssistantMessage["content"],
	timestamp: number,
	extra: Partial<AssistantMessage> = {},
): AssistantMessage {
	return {
		role: "assistant",
		content,
		api: FALLBACK_MODEL,
		provider: FALLBACK_MODEL,
		model: extra.model ?? FALLBACK_MODEL,
		usage: { ...ZERO_USAGE, cost: { ...ZERO_USAGE.cost } },
		stopReason: "stop",
		timestamp,
		...extra,
	};
}

function assistantEntry(
	block: AssistantBlock,
	parentId: string | null,
	timestamp: string,
): MessageEntry {
	const extra: Partial<AssistantMessage> = {};
	if (block.turn?.model) extra.model = block.turn.model;
	if (block.status === "error") {
		extra.stopReason = "error";
		extra.errorMessage = block.error ?? "Error";
	} else if (block.status === "aborted") {
		extra.stopReason = "aborted";
		if (block.error) extra.errorMessage = block.error;
	}
	return {
		type: "message",
		id: block.id,
		parentId,
		timestamp,
		message: assistantMessage([{ type: "text", text: block.text }], block.at, extra),
	};
}

function reasoningEntry(
	block: ReasoningBlock,
	parentId: string | null,
	timestamp: string,
): MessageEntry {
	return {
		type: "message",
		id: block.id,
		parentId,
		timestamp,
		message: assistantMessage([{ type: "thinking", thinking: block.text }], block.at),
	};
}

/** The wire tool name a call is replayed under, so pi-tui picks its matching card. */
function replayToolName(block: ToolBlock): string {
	const named = resolveToolName(block);
	if (named) return named;
	return block.toolKind === "command" ? "bash" : block.toolKind || "tool";
}

function replayToolArgs(block: ToolBlock, name: string): Record<string, unknown> {
	const args = toolArgs(block);
	if (name === "bash" && typeof args.command !== "string" && block.title) {
		return { ...args, command: block.title };
	}
	return args;
}

function toolCallEntry(block: ToolBlock, parentId: string | null, timestamp: string): MessageEntry {
	const name = replayToolName(block);
	return {
		type: "message",
		id: block.id,
		parentId,
		timestamp,
		message: assistantMessage(
			[{ type: "toolCall", id: block.actionId, name, arguments: replayToolArgs(block, name) }],
			block.at,
			{ stopReason: "toolUse" },
		),
	};
}

/**
 * A finished (or saved) tool's result. A call still executing has none, so the
 * card replays as running; a saved receipt never will, so it always resolves.
 */
function toolResultEntry(
	block: ToolBlock,
	parentId: string | null,
	timestamp: string,
): MessageEntry | undefined {
	if (block.phase !== "completed" && !block.historical) return undefined;
	const name = replayToolName(block);
	const result = block.detail?.result;
	const text = typeof result === "string" && result.length > 0 ? result : (block.message ?? "");
	const details = toolDetails(block);
	return {
		type: "message",
		id: `${block.id}${RESULT_ENTRY_SUFFIX}`,
		parentId,
		timestamp,
		message: {
			role: "toolResult",
			toolCallId: block.actionId,
			toolName: name,
			content: text ? [{ type: "text", text }] : [],
			...(Object.keys(details).length > 0 ? { details } : {}),
			isError: block.ok === false,
			timestamp: block.completedAt ?? block.at,
		},
	};
}

function approvalEntry(
	block: ApprovalBlock,
	parentId: string | null,
	timestamp: string,
): CustomEntry {
	const subject = block.tool ? `approval · ${block.tool}` : "approval";
	const state = block.status === "resolved" ? (block.decision ?? "resolved") : "pending";
	return {
		type: "custom_message",
		id: block.id,
		parentId,
		timestamp,
		customType: APPROVAL_CUSTOM_TYPE,
		content: `${subject} · ${state}`,
		details: { approvalId: block.approvalId, status: block.status, decision: block.decision },
		display: true,
	};
}

function noticeEntry(block: NoticeBlock, parentId: string | null, timestamp: string): CustomEntry {
	return {
		type: "custom_message",
		id: block.id,
		parentId,
		timestamp,
		customType: NOTICE_CUSTOM_TYPE,
		content: block.level === "info" ? block.text : `${block.level}: ${block.text}`,
		details: { level: block.level },
		display: true,
	};
}
