/**
 * `^model` mentions in the prompt.
 *
 * omp lets you type `^provider/id` in a prompt: the composer completes it from
 * the session's model scope, and on submit the mention is turned into a tag the
 * agent can delegate to. Lemon's equivalent has no subagent pseudonyms to
 * register, so a submitted mention does the nearest thing the TUI already
 * knows how to do: it switches the focused session to that model (the same
 * `sessions.patch` the Ctrl+O picker sends) and the token is stripped from the
 * prompt text.
 *
 * pi-tui's own `getModelMentionSuggestions` cannot be used here: it ranks omp
 * `Model` objects out of omp's catalog, draws rows with pi-tui's theme
 * singleton (which Lemon never installs — it has its own theme), and offers
 * effort suffixes from omp's model metadata. Lemon's `models.list` rows are
 * plain entries and thinking is set separately (`/think`), so the candidate
 * lookup and completion rows are built here; `MODEL_MENTION_RE` — the
 * dependency-free token syntax — is shared with omp.
 */

import type { AutocompleteItem, ModelMentionCompletion } from "@oh-my-pi/pi-tui/autocomplete";
import { subsequenceMatch, subsequenceScore } from "@oh-my-pi/pi-tui/autocomplete";
import { MODEL_MENTION_RE } from "@oh-my-pi/pi-tui/prompt/model-mention-syntax";
import { MODELS_CACHE_TTL_MS, type ModelEntry, toModelEntries } from "../commands/model.ts";
import { type ControlPlaneMethods, METHOD } from "../protocol/methods.ts";
import type { AppStore } from "../store/app-store.ts";
import type { SessionStore } from "../store/session-store.ts";
import type { NoticeLevel } from "../store/transcript-model.ts";

/** Same cap as omp's popup. */
export const MAX_MODEL_MENTION_SUGGESTIONS = 20;

/** The cursor's token: a `^` at a word boundary, up to the cursor. */
const MENTION_CONTEXT_RE = /(?:^|\s)(\^[^\s]*)$/;

/** Where the composer reads candidate models. */
export interface ModelMentionSource {
	/** What is known right now, with no I/O. */
	entries(): readonly ModelEntry[];
	/** Fetch (or reuse a fresh cache of) the daemon's model list. */
	load(): Promise<readonly ModelEntry[]>;
}

/** The selector Lemon's session model uses: `provider:id` (what the picker patches). */
export function modelMentionSelector(entry: ModelEntry): string {
	return `${entry.provider}:${entry.id}`;
}

/**
 * A mention source over the store's `models.list` cache. The parsed entries are
 * reused while the cache array is unchanged, and concurrent loads share one request.
 */
export function createModelMentionSource(host: {
	store: Pick<AppStore, "models" | "modelsFetchedAtMs">;
	methods: Pick<ControlPlaneMethods, "supports" | "modelsList">;
	now?: () => number;
}): ModelMentionSource {
	const now = host.now ?? Date.now;
	let parsedFrom: unknown;
	let parsed: readonly ModelEntry[] = [];
	let inflight: Promise<readonly ModelEntry[]> | undefined;
	const entries = (): readonly ModelEntry[] => {
		const cached = host.store.models;
		if (cached !== parsedFrom) {
			parsedFrom = cached;
			parsed = toModelEntries({ models: cached ?? [] });
		}
		return parsed;
	};
	const load = (): Promise<readonly ModelEntry[]> => {
		const fresh =
			entries().length > 0 && now() - host.store.modelsFetchedAtMs < MODELS_CACHE_TTL_MS;
		if (fresh || !host.methods.supports(METHOD.modelsList)) return Promise.resolve(entries());
		inflight ??= (async () => {
			try {
				const result = await host.methods.modelsList();
				const models = result?.models;
				if (Array.isArray(models) && models.length > 0) {
					host.store.models = models as Array<Record<string, unknown>>;
					host.store.modelsFetchedAtMs = now();
				}
			} catch {
				// A stale list still completes; the picker reports the failure itself.
			} finally {
				inflight = undefined;
			}
			return entries();
		})();
		return inflight;
	};
	return { entries, load };
}

/** Rank `entries` against the text typed after `^`, best first. */
function rankEntries(query: string, entries: readonly ModelEntry[]): ModelEntry[] {
	if (query.length === 0) return entries.slice(0, MAX_MODEL_MENTION_SUGGESTIONS);
	const lowered = query.toLowerCase();
	const scored: Array<{ entry: ModelEntry; score: number }> = [];
	for (const entry of entries) {
		const haystack = `${modelMentionSelector(entry)} ${entry.name}`.toLowerCase();
		if (!subsequenceMatch(lowered, haystack)) continue;
		scored.push({ entry, score: subsequenceScore(lowered, haystack) });
	}
	// Array#sort is stable, so equal scores keep `models.list` order.
	scored.sort((a, b) => b.score - a.score);
	return scored.slice(0, MAX_MODEL_MENTION_SUGGESTIONS).map((row) => row.entry);
}

/** Whether an autocomplete prefix belongs to a model mention. */
export function isModelMentionPrefix(prefix: string): boolean {
	return prefix.startsWith("^");
}

/** The `^…` token ending at the cursor, or undefined when there is none. */
export function modelMentionPrefix(textBeforeCursor: string): string | undefined {
	return textBeforeCursor.match(MENTION_CONTEXT_RE)?.[1];
}

/** Completion rows for the whitespace-delimited `^` token at the cursor. */
export function getModelMentionSuggestions(
	textBeforeCursor: string,
	entries: readonly ModelEntry[] | undefined,
): ModelMentionCompletion {
	if (!entries) return { kind: "unhandled" };
	const prefix = modelMentionPrefix(textBeforeCursor);
	if (!prefix) return { kind: "unhandled" };
	const items: AutocompleteItem[] = rankEntries(prefix.slice(1), entries).map((entry) => {
		const selector = modelMentionSelector(entry);
		return {
			value: selector,
			label: selector,
			description: entry.name === entry.id ? undefined : entry.name,
		};
	});
	return items.length > 0
		? { kind: "matched", suggestions: { items, prefix } }
		: { kind: "no-match" };
}

/** Replace the live mention token with the chosen selector and a trailing space. */
export function applyModelMentionCompletion(
	lines: string[],
	cursorLine: number,
	cursorCol: number,
	item: AutocompleteItem,
	prefix: string,
): { lines: string[]; cursorLine: number; cursorCol: number } {
	const currentLine = lines[cursorLine] ?? "";
	const before = currentLine.slice(0, cursorCol);
	const live = before.match(MENTION_CONTEXT_RE)?.[1] ?? prefix;
	const start = before.match(MENTION_CONTEXT_RE)
		? before.length - live.length
		: Math.max(0, cursorCol - prefix.length);
	const replacement = `^${item.value} `;
	const newLines = [...lines];
	newLines[cursorLine] = currentLine.slice(0, start) + replacement + currentLine.slice(cursorCol);
	return { lines: newLines, cursorLine, cursorCol: start + replacement.length };
}

/** A mention token resolved to a model the daemon lists. */
export interface ResolvedModelMentions {
	/** The prompt with every resolved mention removed. */
	text: string;
	/** The last resolved mention wins, as the latest word of the user's intent. */
	model?: ModelEntry;
	/** Every resolved mention, in order of appearance. */
	matched: readonly ModelEntry[];
}

/**
 * Resolve `provider:id` (or omp's `provider/id`, or a bare id naming exactly one
 * model) to a listed entry. Unknown tokens are left alone: `^` is also prose.
 */
function resolveToken(token: string, entries: readonly ModelEntry[]): ModelEntry | undefined {
	const exact = entries.find(
		(entry) =>
			`${entry.provider}:${entry.id}` === token || `${entry.provider}/${entry.id}` === token,
	);
	if (exact) return exact;
	const byId = entries.filter((entry) => entry.id === token);
	return byId.length === 1 ? byId[0] : undefined;
}

/**
 * Pull resolved `^model` mentions out of a submitted prompt. Slash commands and
 * shell escapes never carry mentions, and text without a resolvable mention is
 * returned untouched (same string).
 */
export function resolveModelMentions(
	text: string,
	entries: readonly ModelEntry[],
): ResolvedModelMentions {
	const unchanged: ResolvedModelMentions = { text, matched: [] };
	if (!text.includes("^") || /^\s*[!/]/.test(text)) return unchanged;
	const matched: ModelEntry[] = [];
	// A fresh RegExp: the shared one is global, and its lastIndex is mutable state.
	const pattern = new RegExp(MODEL_MENTION_RE.source, MODEL_MENTION_RE.flags);
	const stripped = text.replace(pattern, (whole, lead: string, token: string) => {
		const entry = resolveToken(token, entries);
		if (!entry) return whole;
		matched.push(entry);
		// Keep a line break the mention sat behind; a plain space goes with it.
		return lead.includes("\n") ? lead : "";
	});
	if (matched.length === 0) return unchanged;
	return { text: stripped.trim(), model: matched[matched.length - 1], matched };
}

/** Whether `text` holds a `^` token worth the cost of fetching the model list. */
export function mayContainModelMention(text: string): boolean {
	if (/^\s*[!/]/.test(text)) return false;
	const pattern = new RegExp(MODEL_MENTION_RE.source, MODEL_MENTION_RE.flags);
	return pattern.test(text);
}

export interface ModelMentionSwitchHost {
	methods: Pick<ControlPlaneMethods, "sessionsPatch">;
	session: SessionStore;
	refreshStatus(): void;
	notice(text: string, level?: NoticeLevel): void;
}

/** Switch the session to a mentioned model, as the Ctrl+O picker does. False when the patch failed. */
export async function switchToMentionedModel(
	host: ModelMentionSwitchHost,
	entry: ModelEntry,
): Promise<boolean> {
	const modelId = modelMentionSelector(entry);
	try {
		await host.methods.sessionsPatch({ sessionKey: host.session.key, model: modelId });
	} catch (error) {
		host.notice(
			`could not set model ${modelId}: ${error instanceof Error ? error.message : String(error)}`,
			"error",
		);
		return false;
	}
	host.session.setModel(
		{ model: modelId, provider: entry.provider, contextWindow: entry.contextWindow },
		"local",
	);
	host.refreshStatus();
	host.notice(`model: ${modelId} (session ${host.session.key})`);
	return true;
}
