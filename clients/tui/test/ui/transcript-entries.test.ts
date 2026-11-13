import { describe, expect, test } from "bun:test";
import { transcriptEntryMessage } from "@oh-my-pi/pi-tui/chat/transcript-entry";
import type { Block } from "../../src/store/transcript-model.ts";
import {
	APPROVAL_CUSTOM_TYPE,
	blocksToTranscriptEntries,
	entryBlockId,
	NOTICE_CUSTOM_TYPE,
	RESULT_ENTRY_SUFFIX,
} from "../../src/ui/transcript-entries.ts";

const T0 = Date.UTC(2026, 10, 13, 12, 0, 0);

function convert(...blocks: Block[]) {
	return blocksToTranscriptEntries(blocks);
}

describe("blocksToTranscriptEntries", () => {
	test("a user block is a user message stamped with its send time", () => {
		const [entry] = convert({ id: "user-1", kind: "user", at: T0, sentAt: T0 + 5, text: "hello" });
		expect(entry).toMatchObject({
			type: "message",
			id: "user-1",
			parentId: null,
			timestamp: new Date(T0).toISOString(),
			message: { role: "user", content: "hello", timestamp: T0 + 5 },
		});
	});

	test("user images follow the text as image content", () => {
		const [entry] = convert({
			id: "user-1",
			kind: "user",
			at: T0,
			text: "look [image: a.png]",
			images: [{ type: "image", mime_type: "image/png", data: "QUJD" }],
		});
		expect(transcriptEntryMessage(entry!)).toMatchObject({
			role: "user",
			content: [
				{ type: "text", text: "look [image: a.png]" },
				{ type: "image", mimeType: "image/png", data: "QUJD" },
			],
		});
	});

	test("an assistant block is a text reply; error and aborted status become stop reasons", () => {
		const base = { kind: "assistant", at: T0, runId: "r1", text: "answer" } as const;
		const [done, failed, aborted] = convert(
			{ ...base, id: "assistant-1", status: "done", turn: { model: "gpt-x" } },
			{ ...base, id: "assistant-2", status: "error", error: "boom" },
			{ ...base, id: "assistant-3", status: "aborted" },
		);
		expect(transcriptEntryMessage(done!)).toMatchObject({
			role: "assistant",
			model: "gpt-x",
			stopReason: "stop",
			content: [{ type: "text", text: "answer" }],
		});
		expect(transcriptEntryMessage(failed!)).toMatchObject({
			stopReason: "error",
			errorMessage: "boom",
		});
		expect(transcriptEntryMessage(aborted!)).toMatchObject({ stopReason: "aborted" });
	});

	test("a reasoning block is thinking content; an empty one is dropped", () => {
		const entries = convert(
			{
				id: "reasoning-1",
				kind: "reasoning",
				at: T0,
				runId: "r1",
				actionId: "t1",
				text: "pondering",
				phase: "completed",
			},
			{
				id: "reasoning-2",
				kind: "reasoning",
				at: T0,
				runId: "r1",
				actionId: "t2",
				text: "  ",
				phase: "started",
			},
		);
		expect(entries.map((entry) => entry.id)).toEqual(["reasoning-1"]);
		expect(transcriptEntryMessage(entries[0]!)).toMatchObject({
			role: "assistant",
			content: [{ type: "thinking", thinking: "pondering" }],
		});
	});

	describe("tool blocks", () => {
		const tool = (patch: Partial<Extract<Block, { kind: "tool" }>> = {}): Block => ({
			id: "tool-1",
			kind: "tool",
			at: T0,
			runId: "r1",
			actionId: "call-1",
			toolKind: "command",
			title: "ls -la",
			detail: { name: "bash", args: { command: "ls -la" }, result: "total 0" },
			phase: "completed",
			ok: true,
			message: undefined,
			...patch,
		});

		test("a completed tool is a call plus a result under the block's ids", () => {
			const entries = convert(tool());
			expect(entries.map((entry) => entry.id)).toEqual(["tool-1", `tool-1${RESULT_ENTRY_SUFFIX}`]);
			expect(entries[1]!.parentId).toBe("tool-1");
			expect(transcriptEntryMessage(entries[0]!)).toMatchObject({
				role: "assistant",
				stopReason: "toolUse",
				content: [
					{ type: "toolCall", id: "call-1", name: "bash", arguments: { command: "ls -la" } },
				],
			});
			expect(transcriptEntryMessage(entries[1]!)).toMatchObject({
				role: "toolResult",
				toolCallId: "call-1",
				toolName: "bash",
				isError: false,
				content: [{ type: "text", text: "total 0" }],
			});
		});

		test("a failed tool's result is an error and falls back to the block message", () => {
			const entries = convert(tool({ detail: undefined, ok: false, message: "exit 2" }));
			expect(transcriptEntryMessage(entries[1]!)).toMatchObject({
				isError: true,
				content: [{ type: "text", text: "exit 2" }],
			});
		});

		test("a running tool has a call and no result; a saved receipt always resolves", () => {
			expect(convert(tool({ phase: "started", ok: undefined })).map((e) => e.id)).toEqual([
				"tool-1",
			]);
			expect(
				convert(tool({ phase: "started", ok: undefined, historical: true })).map((e) => e.id),
			).toEqual(["tool-1", "tool-1:result"]);
		});

		test("a command without recorded args replays its title as the bash command", () => {
			const [call] = convert(tool({ detail: undefined }));
			expect(transcriptEntryMessage(call!)).toMatchObject({
				content: [{ type: "toolCall", name: "bash", arguments: { command: "ls -la" } }],
			});
		});

		test("a non-command tool without a recorded name keeps its kind", () => {
			const [call] = convert(tool({ toolKind: "web_search", detail: undefined, title: "q" }));
			expect(transcriptEntryMessage(call!)).toMatchObject({
				content: [{ type: "toolCall", name: "web_search" }],
			});
		});
	});

	test("approvals and notices are visible custom messages", () => {
		const [approval, pending, notice, warning] = convert(
			{
				id: "approval-1",
				kind: "approval",
				at: T0,
				approvalId: "ap1",
				tool: "bash",
				status: "resolved",
				decision: "allow",
			},
			{
				id: "approval-2",
				kind: "approval",
				at: T0,
				approvalId: "ap2",
				tool: undefined,
				status: "pending",
			},
			{ id: "notice-1", kind: "notice", at: T0, level: "info", text: "compacted" },
			{ id: "notice-2", kind: "notice", at: T0, level: "warning", text: "slow" },
		);
		expect(approval).toMatchObject({
			type: "custom_message",
			customType: APPROVAL_CUSTOM_TYPE,
			content: "approval · bash · allow",
			display: true,
		});
		expect(pending).toMatchObject({ content: "approval · pending" });
		expect(notice).toMatchObject({
			type: "custom_message",
			customType: NOTICE_CUSTOM_TYPE,
			content: "compacted",
			display: true,
		});
		expect(warning).toMatchObject({ content: "warning: slow" });
		expect(transcriptEntryMessage(notice!)).toMatchObject({ role: "custom", display: true });
	});

	test("entries chain in transcript order and ids are unique", () => {
		const entries = convert(
			{ id: "user-1", kind: "user", at: T0, text: "q" },
			{
				id: "tool-1",
				kind: "tool",
				at: T0,
				runId: "r",
				actionId: "c",
				toolKind: "tool",
				title: "x",
				detail: undefined,
				phase: "completed",
				ok: true,
				message: "done",
			},
			{ id: "assistant-1", kind: "assistant", at: T0, runId: "r", status: "done", text: "a" },
		);
		expect(entries.map((entry) => entry.parentId)).toEqual([
			null,
			"user-1",
			"tool-1",
			"tool-1:result",
		]);
		expect(new Set(entries.map((entry) => entry.id)).size).toBe(entries.length);
	});
});

test("entryBlockId maps every entry id back to its block", () => {
	expect(entryBlockId("tool-7")).toBe("tool-7");
	expect(entryBlockId(`tool-7${RESULT_ENTRY_SUFFIX}`)).toBe("tool-7");
	expect(entryBlockId("user-2")).toBe("user-2");
});
