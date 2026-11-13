/**
 * The composer's composite autocomplete: precedence between slash commands,
 * `^model`, `#N`, emoji and the base provider, and `^model` resolution on submit.
 */

import { describe, expect, test } from "bun:test";
import type { ModelEntry } from "../../src/commands/model.ts";
import { createComposerAutocompleteProvider } from "../../src/composer/autocomplete.ts";
import {
	getModelMentionSuggestions,
	type ModelMentionSource,
	resolveModelMentions,
} from "../../src/composer/model-mentions.ts";

const entry = (provider: string, id: string, name = id): ModelEntry => ({
	provider,
	id,
	name,
	supportsThinking: false,
	supportsVision: false,
});

const ENTRIES = [
	entry("anthropic", "claude-sonnet-4", "Claude Sonnet 4"),
	entry("anthropic", "claude-opus-4"),
	entry("openai", "gpt-4o"),
];

const models: ModelMentionSource = {
	entries: () => ENTRIES,
	load: async () => ENTRIES,
};

const COMMANDS = [
	{ name: "model", description: "pick a model", allowArgs: true },
	{ name: "memo", description: "note", allowArgs: true },
];

function provider() {
	return createComposerAutocompleteProvider({
		commands: COMMANDS,
		basePath: process.cwd(),
		models,
	});
}

async function suggest(text: string, p = provider()) {
	return await p.getSuggestions([text], 0, text.length);
}

describe("composer autocomplete precedence", () => {
	test("^ offers daemon models as provider:id", async () => {
		const result = await suggest("use ^son");
		expect(result?.prefix).toBe("^son");
		expect(result?.items.map((item) => item.value)).toEqual(["anthropic:claude-sonnet-4"]);
	});

	test("a bare ^ lists every model", async () => {
		const result = await suggest("^");
		expect(result?.items).toHaveLength(ENTRIES.length);
	});

	test("accepting a ^ row writes the selector and a trailing space", () => {
		const p = provider();
		const applied = p.applyCompletion(
			["use ^son rest"],
			0,
			8,
			{ value: "anthropic:claude-sonnet-4", label: "x" },
			"^son",
		);
		expect(applied.lines[0]).toBe("use ^anthropic:claude-sonnet-4  rest");
		expect(applied.cursorCol).toBe("use ^anthropic:claude-sonnet-4 ".length);
	});

	test("#12 offers pr and issue refs and accepts as scheme://N", async () => {
		const p = provider();
		const result = await suggest("see #12", p);
		expect(result?.items.map((item) => item.value)).toEqual(["pr://12", "issue://12"]);
		const applied = p.applyCompletion(["see #12"], 0, 7, result!.items[1]!, result!.prefix);
		expect(applied.lines[0]).toBe("see issue://12 ");
	});

	test("a typed qualifier narrows #N to that kind", async () => {
		const result = await suggest("fix issue #7");
		expect(result?.items.map((item) => item.value)).toEqual(["issue://7"]);
	});

	test(":sm offers emoji and accepting replaces the token", async () => {
		const p = provider();
		const result = await suggest("hi :smi", p);
		expect(result?.prefix).toBe(":smi");
		expect(result!.items.length).toBeGreaterThan(0);
		const item = result!.items[0]!;
		const applied = p.applyCompletion(["hi :smi"], 0, 7, item, result!.prefix);
		expect(applied.lines[0]).toBe(`hi ${item.value}`);
	});

	test("emoji can be turned off", async () => {
		const p = createComposerAutocompleteProvider({
			commands: COMMANDS,
			basePath: process.cwd(),
			emoji: false,
		});
		expect(await suggest("hi :smi", p)).toBeNull();
		expect(p.trySyncInlineReplace(":joy:")).toBeNull();
	});

	test("inline :shortcode: replacement is exposed to the editor", () => {
		expect(provider().trySyncInlineReplace("hi :joy:")).toEqual({ replaceLen: 5, insert: "😂" });
	});

	test("slash command names still come from the base provider", async () => {
		const result = await suggest("/mo");
		expect(result?.prefix).toBe("/mo");
		expect(result?.items.length).toBeGreaterThanOrEqual(2);
	});

	test("inside slash arguments ^ and #N keep working but emoji does not preempt the command", async () => {
		const mention = await suggest("/model ^gpt");
		expect(mention?.items.map((item) => item.value)).toEqual(["openai:gpt-4o"]);
		const ref = await suggest("/model #5");
		expect(ref?.items.map((item) => item.value)).toEqual(["pr://5", "issue://5"]);
	});

	test("#N outranks a ^ token earlier on the line", async () => {
		const result = await suggest("^x #3");
		expect(result?.items.map((item) => item.value)).toEqual(["pr://3", "issue://3"]);
	});

	test("without a model source ^ is plain text", async () => {
		const p = createComposerAutocompleteProvider({ commands: COMMANDS, basePath: process.cwd() });
		expect(await suggest("hello ^son", p)).toBeNull();
		expect(p.trySyncModelMentionCompletion(["hello ^son"], 0, 10)).toEqual({ kind: "unhandled" });
	});

	test("sync ^ completion reads the cached entries and defers to #N and slash args", () => {
		const p = provider();
		const sync = p.trySyncModelMentionCompletion(["^opus"], 0, 5);
		expect(sync.kind).toBe("matched");
		expect(p.trySyncModelMentionCompletion(["^opus #3"], 0, 8).kind).toBe("unhandled");
		expect(p.trySyncModelMentionCompletion(["/model ^opus"], 0, 12).kind).toBe("unhandled");
		expect(getModelMentionSuggestions("^zzzz", ENTRIES).kind).toBe("no-match");
	});
});

describe("submitted ^model mentions", () => {
	test("a resolved mention is stripped and names the model", () => {
		const result = resolveModelMentions("^openai:gpt-4o explain this", ENTRIES);
		expect(result.text).toBe("explain this");
		expect(result.model?.id).toBe("gpt-4o");
	});

	test("omp's provider/id form and mid-sentence mentions resolve", () => {
		const result = resolveModelMentions("explain ^anthropic/claude-opus-4 this", ENTRIES);
		expect(result.text).toBe("explain this");
		expect(result.model?.id).toBe("claude-opus-4");
	});

	test("the last mention wins", () => {
		const result = resolveModelMentions("^openai:gpt-4o hi ^anthropic:claude-opus-4", ENTRIES);
		expect(result.model?.id).toBe("claude-opus-4");
		expect(result.matched).toHaveLength(2);
		expect(result.text).toBe("hi");
	});

	test("unknown tokens, slash commands and shell lines are left alone", () => {
		for (const text of ["x ^nope y", "/model ^openai:gpt-4o", "!echo ^openai:gpt-4o"]) {
			const result = resolveModelMentions(text, ENTRIES);
			expect(result.text).toBe(text);
			expect(result.model).toBeUndefined();
		}
	});

	test("a bare id resolves only when it names exactly one model", () => {
		expect(resolveModelMentions("^gpt-4o hi", ENTRIES).model?.provider).toBe("openai");
		const dup = [...ENTRIES, entry("azure", "gpt-4o")];
		expect(resolveModelMentions("^gpt-4o hi", dup).model).toBeUndefined();
	});
});
