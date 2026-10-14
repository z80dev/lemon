/**
 * Defensive reading of a `sessions.context` receipt.
 *
 * The receipt drives a panel that claims to account for every token in the
 * context window, so a malformed core (no session key, no total) is refused
 * outright rather than half-rendered. Optional parts degrade individually:
 * an unknown category id is dropped and its tokens are kept as `otherTokens`,
 * an unreadable compaction block becomes "not reported", and labels are
 * stripped of control characters and bounded before they reach a terminal.
 */

import { asArray, asRecord, pickBoolean, pickNumber, pickString } from "../commands/format.ts";
import type {
	ContextAutoCompaction,
	ContextCategoryId,
	ContextCategoryUsage,
	ContextContributor,
	ContextSessionUsage,
	SessionsContextResult,
} from "./types.ts";

/** The contract's fixed order; `unattributed` only appears when overhead was never recorded. */
export const CONTEXT_CATEGORY_IDS: readonly ContextCategoryId[] = [
	"system_prompt",
	"tool_definitions",
	"skills",
	"context_files",
	"memory",
	"user_messages",
	"assistant_messages",
	"tool_results",
	"summaries",
	"unattributed",
];

export const CONTEXT_CATEGORY_LABELS: Readonly<Record<ContextCategoryId, string>> = {
	system_prompt: "System prompt",
	tool_definitions: "Tool definitions",
	skills: "Skills",
	context_files: "Context files",
	memory: "Memory",
	user_messages: "User messages",
	assistant_messages: "Assistant messages",
	tool_results: "Tool results",
	summaries: "Summaries",
	unattributed: "System prompt and tools (not itemized)",
};

const LABEL_LIMIT = 80;
const TOP_LIMIT = 10;
const SOURCES = ["usage", "usage+estimate", "estimate"] as const;
const OVERHEADS = ["live", "snapshot", "unavailable"] as const;

export class InvalidContextReceiptError extends Error {
	constructor() {
		super("invalid sessions.context receipt");
		this.name = "InvalidContextReceiptError";
	}
}

export function isContextCategoryId(value: unknown): value is ContextCategoryId {
	return typeof value === "string" && (CONTEXT_CATEGORY_IDS as readonly string[]).includes(value);
}

/** Validate and normalize a raw receipt; throws {@link InvalidContextReceiptError} on a bad core. */
export function parseSessionsContext(raw: unknown): SessionsContextResult {
	const record = asRecord(raw);
	const sessionKey = typeof record?.sessionKey === "string" ? record.sessionKey : undefined;
	const usedTokens = count(pickNumber(record, "usedTokens"));
	if (!record || !sessionKey || usedTokens === undefined) throw new InvalidContextReceiptError();

	const window = positive(pickNumber(record, "window")) ?? null;
	const byId = new Map<ContextCategoryId, ContextCategoryUsage>();
	for (const entry of asArray(record.categories)) {
		const id = pickString(entry, "id");
		const tokens = count(pickNumber(entry, "tokens"));
		if (!isContextCategoryId(id) || tokens === undefined || byId.has(id)) continue;
		const percent = pickNumber(entry, "percent");
		byId.set(id, {
			id,
			label: cleanLabel(pickString(entry, "label")) ?? CONTEXT_CATEGORY_LABELS[id],
			tokens,
			percent: percent ?? (window === null ? null : share(tokens, window)),
			items: count(pickNumber(entry, "items")),
		});
	}
	const categories = CONTEXT_CATEGORY_IDS.flatMap((id) => {
		const category = byId.get(id);
		return category ? [category] : [];
	});
	const known = categories.reduce((sum, category) => sum + category.tokens, 0);

	const top: ContextContributor[] = [];
	for (const entry of asArray(record.top)) {
		const label = cleanLabel(pickString(entry, "label"));
		const tokens = count(pickNumber(entry, "tokens"));
		if (!label || tokens === undefined) continue;
		const category = pickString(entry, "category");
		top.push({ category: isContextCategoryId(category) ? category : undefined, label, tokens });
	}
	top.sort((a, b) => b.tokens - a.tokens);

	const source = pickString(record, "source");
	const overhead = pickString(record, "overhead");
	const modelId = cleanLabel(pickString(record, "model.id"));
	const freeTokens =
		window === null
			? null
			: (count(pickNumber(record, "freeTokens")) ?? Math.max(window - usedTokens, 0));

	return {
		sessionKey,
		live: pickBoolean(record, "live") === true,
		// Unknown values fall back to the variant that claims the least.
		overhead: (OVERHEADS as readonly string[]).includes(overhead ?? "")
			? (overhead as SessionsContextResult["overhead"])
			: "unavailable",
		model: modelId
			? { provider: cleanLabel(pickString(record, "model.provider")), id: modelId }
			: null,
		window,
		usedTokens,
		freeTokens,
		percentUsed:
			window === null ? null : (pickNumber(record, "percentUsed") ?? share(usedTokens, window)),
		source: (SOURCES as readonly string[]).includes(source ?? "")
			? (source as SessionsContextResult["source"])
			: "estimate",
		estimatedTokens: count(pickNumber(record, "estimatedTokens")),
		autoCompaction: window === null ? null : autoCompaction(record.autoCompaction),
		categories,
		otherTokens: Math.max(0, usedTokens - known),
		top: top.slice(0, TOP_LIMIT),
		messageCount: count(pickNumber(record, "messageCount")),
		usage: sessionUsage(record.usage),
		measuredAt: positive(pickNumber(record, "measuredAt")),
	};
}

function autoCompaction(raw: unknown): ContextAutoCompaction | null {
	const thresholdTokens = positive(pickNumber(raw, "thresholdTokens"));
	const enabled = pickBoolean(raw, "enabled");
	if (thresholdTokens === undefined || enabled === undefined) return null;
	return {
		enabled,
		thresholdTokens,
		reserveTokens: count(pickNumber(raw, "reserveTokens")),
		headroomTokens: count(pickNumber(raw, "headroomTokens")),
	};
}

/** Optional per-session spend block; absent from older daemons and malformed values. */
function sessionUsage(raw: unknown): ContextSessionUsage | undefined {
	if (!asRecord(raw)) return undefined;
	const tokens = count(pickNumber(raw, "tokens"));
	const input = count(pickNumber(raw, "input"));
	const output = count(pickNumber(raw, "output"));
	if (tokens === undefined || input === undefined || output === undefined) return undefined;
	const costUsd = pickNumber(raw, "costUsd");
	return {
		tokens,
		costUsd: costUsd !== undefined && costUsd >= 0 ? costUsd : 0,
		input,
		output,
		cacheRead: count(pickNumber(raw, "cacheRead")) ?? 0,
		cacheWrite: count(pickNumber(raw, "cacheWrite")) ?? 0,
		assistantMessages: count(pickNumber(raw, "assistantMessages")) ?? 0,
	};
}

/** Percent of `whole`, one decimal. */
function share(part: number, whole: number): number {
	return Math.round((part / whole) * 1000) / 10;
}

function count(value: number | undefined): number | undefined {
	return value !== undefined && value >= 0 ? Math.round(value) : undefined;
}

function positive(value: number | undefined): number | undefined {
	return value !== undefined && value > 0 ? Math.round(value) : undefined;
}

/** Server labels are bounded by contract; the client bounds them again and strips controls. */
function cleanLabel(value: string | undefined): string | undefined {
	const text = value
		?.replace(/\p{Cc}/gu, " ")
		.replace(/\s+/g, " ")
		.trim();
	if (!text) return undefined;
	return text.length > LABEL_LIMIT ? `${text.slice(0, LABEL_LIMIT - 1)}…` : text;
}
