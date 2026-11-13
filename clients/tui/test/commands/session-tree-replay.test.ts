import { expect, test } from "bun:test";
import {
	pairPromptsWithServerEntries,
	rewindTargetForEntry,
} from "../../src/commands/session-tree.ts";
import type { SessionTreeEntry } from "../../src/protocol/session-tree.ts";
import type { Block } from "../../src/store/transcript-model.ts";

const prompt = (id: string, text: string | null, rewindable = true): SessionTreeEntry => ({
	id,
	parentId: null,
	type: "message",
	role: "user",
	text,
	isActive: true,
	isLeaf: false,
	rewindable,
});

const user = (id: string, text: string): Block => ({ id, kind: "user", at: 1, text });
const reply = (id: string): Block => ({
	id,
	kind: "assistant",
	at: 1,
	runId: "r",
	status: "done",
	text: "ok",
});
const tool = (id: string): Block => ({
	id,
	kind: "tool",
	at: 1,
	runId: "r",
	actionId: id,
	toolKind: "tool",
	title: "t",
	detail: undefined,
	phase: "completed",
	ok: true,
	message: undefined,
});

const blocks: Block[] = [
	user("user-1", "first  prompt"),
	reply("assistant-1"),
	user("user-2", "second prompt"),
	tool("tool-1"),
	reply("assistant-2"),
];

test("transcript prompts pair with journal prompts, tolerating whitespace and bounded previews", () => {
	const paired = pairPromptsWithServerEntries(blocks, [
		prompt("s1", "first prompt"),
		prompt("s2", "second"),
	]);
	expect([...paired].map(([blockId, entry]) => [blockId, entry.id])).toEqual([
		["user-2", "s2"],
		["user-1", "s1"],
	]);
});

test("pairing runs newest first, so a client holding only the tail still aligns", () => {
	const paired = pairPromptsWithServerEntries(blocks, [
		prompt("s0", "older prompt the client never loaded"),
		prompt("s1", "first prompt"),
		prompt("s2", "second prompt"),
	]);
	expect(paired.get("user-1")?.id).toBe("s1");
	expect(paired.get("user-2")?.id).toBe("s2");
});

test("a prompt the journal does not hold stays unpaired", () => {
	const paired = pairPromptsWithServerEntries(blocks, [prompt("s2", "second prompt")]);
	expect(paired.has("user-1")).toBe(false);
	expect(paired.get("user-2")?.id).toBe("s2");
});

test("a user turn rewinds before its own prompt", () => {
	const paired = pairPromptsWithServerEntries(blocks, [
		prompt("s1", "first prompt"),
		prompt("s2", "second prompt"),
	]);
	expect(rewindTargetForEntry(blocks, paired, "user-1")?.id).toBe("s1");
	expect(rewindTargetForEntry(blocks, paired, "user-2")?.id).toBe("s2");
});

test("any other turn rewinds before the next prompt, via its block id", () => {
	const paired = pairPromptsWithServerEntries(blocks, [
		prompt("s1", "first prompt"),
		prompt("s2", "second prompt"),
	]);
	expect(rewindTargetForEntry(blocks, paired, "assistant-1")?.id).toBe("s2");
	// A tool result entry resolves through its block; no prompt follows it.
	expect(rewindTargetForEntry(blocks, paired, "tool-1:result")).toBeUndefined();
	expect(rewindTargetForEntry(blocks, paired, "missing")).toBeUndefined();
});

test("a turn after the last prompt has nothing to rewind to", () => {
	const paired = pairPromptsWithServerEntries(blocks, [
		prompt("s1", "first prompt"),
		prompt("s2", "second prompt"),
	]);
	expect(rewindTargetForEntry(blocks, paired, "assistant-2")).toBeUndefined();
});
