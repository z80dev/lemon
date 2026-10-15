import { afterEach, expect, test } from "bun:test";
import { fencedCodeBlocks, selectCopyText } from "../../src/commands/copy.ts";
import type { Block } from "../../src/store/transcript-model.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

let harness: Harness | undefined;
afterEach(() => {
	harness?.stop();
	harness = undefined;
});

const blocks: Block[] = [
	{ id: "u1", kind: "user", at: 1, text: "old prompt" },
	{ id: "a1", kind: "assistant", at: 2, runId: "old", status: "done", text: "old reply" },
	{ id: "u2", kind: "user", at: 3, text: "last prompt" },
	{
		id: "a2",
		kind: "assistant",
		at: 4,
		runId: "new",
		status: "done",
		text: "First\n\n```ts\nconst a = 1;\n```",
	},
	{ id: "n", kind: "notice", at: 5, level: "info", text: "not part of reply" },
	{
		id: "a3",
		kind: "assistant",
		at: 6,
		runId: "new",
		status: "done",
		text: "Last\n\n~~~sh\nprintf hello\n~~~",
	},
];

test("copy selects the whole latest reply across segments, prompt, and one-based code blocks", () => {
	expect(selectCopyText(blocks, [])).toBe(
		"First\n\n```ts\nconst a = 1;\n```\n\nLast\n\n~~~sh\nprintf hello\n~~~",
	);
	expect(selectCopyText(blocks, ["prompt"])).toBe("last prompt");
	expect(selectCopyText(blocks, ["code"])).toBe("const a = 1;");
	expect(selectCopyText(blocks, ["code", "2"])).toBe("printf hello");
});

test("fenced code uses renderer parsing: nesting, long fences, indented code and inline code", () => {
	const source =
		"`inline`\n\n    indented\n\n> ```js\n> quoted()\n> ```\n\n- item\n\n  ~~~\n  nested()\n  ~~~\n\n````markdown\n```inner\n````";
	expect(fencedCodeBlocks(source)).toEqual(["quoted()", "nested()", "```inner"]);
});

test.each(
	[
		["other"],
		["prompt", "1"],
		["code", "0"],
		["code", "-1"],
		["code", "1.5"],
		["code", "1e2"],
		["code", "9007199254740992"],
		["code", "1", "extra"],
	].map((argv) => ({ argv })),
)("invalid copy syntax fails without selecting text: %j", ({ argv }) => {
	expect(() => selectCopyText(blocks, argv)).toThrow("Usage:");
});

test("missing replies, prompts, and code blocks are explicit errors", () => {
	expect(() => selectCopyText([], [])).toThrow("No assistant reply");
	expect(() => selectCopyText([], ["prompt"])).toThrow("No user prompt");
	expect(() => selectCopyText(blocks, ["code", "3"])).toThrow("No code block 3");
});

test("registry dispatches /copy locally even offline, and never notices copied text", async () => {
	harness = await createHarness();
	const copied: string[] = [];
	Object.assign(harness.host, {
		copyText: async (text: string) => {
			copied.push(text);
		},
	});
	harness.store.focused.blocks.push(...blocks);
	harness.client.close();
	const requestsBefore = harness.server.received.length;
	await harness.run("/copy code 2");
	await harness.run("/copy prompt");
	expect(copied).toEqual(["printf hello", "last prompt"]);
	expect(harness.host.text).toBe("");
	await harness.run("/copy code 0");
	expect(copied).toHaveLength(2);
	expect(harness.host.last?.level).toBe("error");
	expect(harness.server.received).toHaveLength(requestsBefore);
});
