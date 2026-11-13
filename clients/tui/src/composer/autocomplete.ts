/**
 * The composer's autocomplete provider.
 *
 * pi-tui's {@link CombinedAutocompleteProvider} owns slash commands and `@file`
 * completion. This provider wraps it and adds the omp prompt sources that
 * apply to Lemon:
 *
 *   `^model`   models the daemon lists (see ./model-mentions.ts)
 *   `#123`     GitHub PR / issue references, accepted as `pr://123` / `issue://123`
 *   `:smile`   emoji shortcodes and emoticons, plus inline `:smile:` replacement
 *
 * Precedence mirrors omp's `PromptActionAutocompleteProvider` (minus the `#`
 * prompt actions and `scheme://` completion Lemon has no use for): inside a
 * slash command's arguments the command's own completion wins; elsewhere a
 * `^` mention is tried first, then `#N`, then emoji, and everything else —
 * slash command names, `@file`, paths — falls through to the base provider
 * untouched.
 */

import {
	type AutocompleteItem,
	type AutocompleteProvider,
	CombinedAutocompleteProvider,
	findLeadingSlashCommandStart,
	type ModelMentionCompletion,
	type SlashCommand,
} from "@oh-my-pi/pi-tui/autocomplete";
import {
	applyEmojiCompletion,
	getEmojiSuggestions,
	isEmojiPrefix,
	tryEmojiInlineReplace,
} from "@oh-my-pi/pi-tui/prompt/emoji-autocomplete";
import {
	getGithubRefContext,
	getGithubRefSuggestions,
} from "@oh-my-pi/pi-tui/prompt/github-ref-autocomplete";
import { applyInternalUrlCompletion } from "@oh-my-pi/pi-tui/prompt/internal-url-autocomplete";
import {
	applyModelMentionCompletion,
	getModelMentionSuggestions,
	isModelMentionPrefix,
	type ModelMentionSource,
} from "./model-mentions.ts";

type Suggestions = { items: AutocompleteItem[]; prefix: string };
type Applied = { lines: string[]; cursorLine: number; cursorCol: number; onApplied?: () => void };

export interface ComposerAutocompleteOptions {
	commands: SlashCommand[];
	basePath: string;
	/** Models for `^` mentions; unset leaves `^` as plain text. */
	models?: ModelMentionSource;
	/** Turn `:smile` completion and inline emoji replacement off. Default on. */
	emoji?: boolean;
}

/** Rewrite an accepted `#N` row to `pr://N` / `issue://N`, honouring a typed `pr`/`issue` qualifier. */
function applyGithubRefCompletion(
	lines: string[],
	cursorLine: number,
	cursorCol: number,
	item: AutocompleteItem,
	prefix: string,
): Applied | null {
	if (!getGithubRefContext(prefix)) return null;
	const scheme = item.value.startsWith("pr://")
		? "pr"
		: item.value.startsWith("issue://")
			? "issue"
			: null;
	if (!scheme) return { lines, cursorLine, cursorCol };
	const currentLine = lines[cursorLine] || "";
	const live = getGithubRefContext(currentLine.slice(0, cursorCol));
	// The popup went stale (the token changed under it): accepting does nothing.
	if (!live || (live.qualifier && live.qualifier !== scheme)) {
		return { lines, cursorLine, cursorCol };
	}
	return applyInternalUrlCompletion(
		lines,
		cursorLine,
		cursorCol,
		{ ...item, value: `${scheme}://${live.number}` },
		live.prefix,
	);
}

export class ComposerAutocompleteProvider implements AutocompleteProvider {
	readonly #commands: SlashCommand[];
	readonly #base: CombinedAutocompleteProvider;
	readonly #models: ModelMentionSource | undefined;
	readonly #emoji: boolean;

	constructor(options: ComposerAutocompleteOptions) {
		this.#commands = options.commands;
		this.#base = new CombinedAutocompleteProvider(options.commands, options.basePath);
		this.#models = options.models;
		this.#emoji = options.emoji !== false;
	}

	async getSuggestions(
		lines: string[],
		cursorLine: number,
		cursorCol: number,
		signal?: AbortSignal,
		onPartial?: (suggestions: Suggestions) => void,
	): Promise<Suggestions | null> {
		if (signal?.aborted) return null;
		const before = (lines[cursorLine] || "").slice(0, cursorCol);
		const inArguments = this.#isInSlashCommandArguments(lines, cursorLine, before);
		const outranked = inArguments || getGithubRefContext(before) !== null;
		if (!outranked) {
			const mention = await this.#mentionSuggestions(before, signal);
			if (mention) return mention;
		}
		if (inArguments) {
			const argument = await this.#base.getSuggestions(
				lines,
				cursorLine,
				cursorCol,
				signal,
				onPartial,
			);
			if (argument) return argument;
			const mention = await this.#mentionSuggestions(before, signal);
			if (mention) return mention;
			return getGithubRefSuggestions(before);
		}
		const githubRef = getGithubRefSuggestions(before);
		if (githubRef) return githubRef;
		if (this.#emoji) {
			const emoji = getEmojiSuggestions(before);
			if (emoji) return emoji;
		}
		return this.#base.getSuggestions(lines, cursorLine, cursorCol, signal, onPartial);
	}

	applyCompletion(
		lines: string[],
		cursorLine: number,
		cursorCol: number,
		item: AutocompleteItem,
		prefix: string,
	): Applied {
		const githubRef = applyGithubRefCompletion(lines, cursorLine, cursorCol, item, prefix);
		if (githubRef) return githubRef;
		if (isModelMentionPrefix(prefix)) {
			return applyModelMentionCompletion(lines, cursorLine, cursorCol, item, prefix);
		}
		if (this.#emoji && isEmojiPrefix(prefix)) {
			return applyEmojiCompletion(lines, cursorLine, cursorCol, item, prefix);
		}
		return this.#base.applyCompletion(lines, cursorLine, cursorCol, item, prefix);
	}

	getInlineHint(lines: string[], cursorLine: number, cursorCol: number): string | null {
		return this.#base.getInlineHint?.(lines, cursorLine, cursorCol) ?? null;
	}

	trySyncSlashCompletion(textBeforeCursor: string): Suggestions | null {
		return this.#base.trySyncSlashCompletion?.(textBeforeCursor) ?? null;
	}

	/** Re-rank a shown `^` popup against the models already cached; the async path refreshes the cache. */
	trySyncModelMentionCompletion(
		lines: string[],
		cursorLine: number,
		cursorCol: number,
	): ModelMentionCompletion {
		const before = (lines[cursorLine] || "").slice(0, cursorCol);
		if (
			this.#isInSlashCommandArguments(lines, cursorLine, before) ||
			getGithubRefContext(before) !== null
		) {
			return { kind: "unhandled" };
		}
		return getModelMentionSuggestions(before, this.#models?.entries());
	}

	trySyncInlineReplace(textBeforeCursor: string): { replaceLen: number; insert: string } | null {
		return this.#emoji ? tryEmojiInlineReplace(textBeforeCursor) : null;
	}

	getForceFileSuggestions(
		lines: string[],
		cursorLine: number,
		cursorCol: number,
		signal?: AbortSignal,
	): Promise<Suggestions | null> {
		return this.#base.getForceFileSuggestions(lines, cursorLine, cursorCol, signal);
	}

	shouldTriggerFileCompletion(lines: string[], cursorLine: number, cursorCol: number): boolean {
		return this.#base.shouldTriggerFileCompletion(lines, cursorLine, cursorCol);
	}

	async #mentionSuggestions(before: string, signal?: AbortSignal): Promise<Suggestions | null> {
		if (!this.#models || !/(?:^|\s)\^[^\s]*$/.test(before)) return null;
		// First `^` of a session: the cache may be empty or stale, so wait for it.
		const entries = await this.#models.load();
		if (signal?.aborted) return null;
		const completion = getModelMentionSuggestions(before, entries);
		return completion.kind === "matched" ? completion.suggestions : null;
	}

	#isInSlashCommandArguments(lines: string[], cursorLine: number, before: string): boolean {
		const start = findLeadingSlashCommandStart(before);
		if (start === null || lines.slice(0, cursorLine).some((line) => (line || "").trim() !== "")) {
			return false;
		}
		const commandText = before.slice(start);
		const space = commandText.indexOf(" ");
		if (space === -1) return false;
		const name = commandText.slice(1, space);
		const command = this.#commands.find((c) => c.name === name || c.aliases?.includes(name));
		return command !== undefined && command.allowArgs !== false;
	}
}

export function createComposerAutocompleteProvider(
	options: ComposerAutocompleteOptions,
): ComposerAutocompleteProvider {
	return new ComposerAutocompleteProvider(options);
}
