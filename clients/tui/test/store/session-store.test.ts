import { beforeEach, describe, expect, test } from "bun:test";
import { SessionStore } from "../../src/store/session-store.ts";
import { resetBlockIds } from "../../src/store/transcript-model.ts";

beforeEach(() => {
	resetBlockIds();
});

describe("SessionStore deltas", () => {
	test("accumulates deltas into one assistant block", () => {
		const session = new SessionStore("s");
		session.appendDelta("run-1", 1, "Hello ");
		const { block } = session.appendDelta("run-1", 2, "world");
		expect(block.text).toBe("Hello world");
		expect(session.blocks.filter((b) => b.kind === "assistant")).toHaveLength(1);
	});

	test("drops replayed and out-of-order sequence numbers", () => {
		const session = new SessionStore("s");
		session.appendDelta("run-1", 1, "a");
		session.appendDelta("run-1", 2, "b");
		const replay = session.appendDelta("run-1", 2, "b");
		const stale = session.appendDelta("run-1", 1, "a");
		expect(replay.accepted).toBe(false);
		expect(stale.accepted).toBe(false);
		expect(session.bufferFor("run-1")).toBe("ab");
	});

	test("keeps per-run sequence state separate", () => {
		const session = new SessionStore("s");
		session.appendDelta("run-1", 5, "one");
		const other = session.appendDelta("run-2", 1, "two");
		expect(other.accepted).toBe(true);
		expect(session.bufferFor("run-2")).toBe("two");
	});

	test("a delta with a non-numeric seq is still accepted", () => {
		const session = new SessionStore("s");
		session.appendDelta("run-1", Number.NaN, "x");
		expect(session.bufferFor("run-1")).toBe("x");
	});
});

describe("SessionStore finalize", () => {
	test("prefers the delta buffer over the truncated answer", () => {
		const session = new SessionStore("s");
		session.appendDelta("run-1", 1, "the complete answer text");
		const block = session.finalizeRun("run-1", { ok: true, answer: "the complete answ" });
		expect(block?.text).toBe("the complete answer text");
		expect(block?.status).toBe("done");
	});

	test("falls back to the answer when nothing streamed", () => {
		const session = new SessionStore("s");
		session.ensureAssistant("run-1");
		const block = session.finalizeRun("run-1", { ok: true, answer: "short reply" });
		expect(block?.text).toBe("short reply");
	});

	test("a failed run records the error separately from the body", () => {
		const session = new SessionStore("s");
		session.appendDelta("run-1", 1, "partial output");
		const block = session.finalizeRun("run-1", { ok: false, answer: "provider exploded" });
		expect(block?.status).toBe("error");
		expect(block?.text).toBe("partial output");
		expect(block?.error).toBe("provider exploded");
	});

	test("an interrupted run keeps its partial text", () => {
		const session = new SessionStore("s");
		session.activeRunId = "run-1";
		session.busy = true;
		session.appendDelta("run-1", 1, "half a thou");
		const block = session.markInterrupted("run-1");
		expect(block?.status).toBe("aborted");
		expect(block?.text).toBe("half a thou");
		expect(session.busy).toBe(false);
		expect(session.activeRunId).toBeUndefined();
	});

	test("a replayed delta after finalize is still ignored", () => {
		const session = new SessionStore("s");
		session.appendDelta("run-1", 2, "done");
		session.finalizeRun("run-1", { ok: true });
		const replay = session.appendDelta("run-1", 2, "done");
		expect(replay.accepted).toBe(false);
		expect(replay.amended).toBe(false);
		expect(session.assistantFor("run-1")?.text).toBe("done");
	});

	test("a late higher-seq delta amends the finalized block", () => {
		// `completed` overtook the tail of the stream; the tail is not a replay.
		const session = new SessionStore("s");
		session.appendDelta("run-1", 1, "the answer is ");
		session.finalizeRun("run-1", { ok: true, answer: "the answer is" });
		const late = session.appendDelta("run-1", 2, "42");
		expect(late.accepted).toBe(true);
		expect(late.amended).toBe(true);
		expect(late.block.text).toBe("the answer is 42");
		expect(late.block.status).toBe("done");
		expect(session.bufferFor("run-1")).toBe("the answer is 42");
	});

	test("a late delta supersedes an answer-only body instead of appending to it", () => {
		const session = new SessionStore("s");
		session.ensureAssistant("run-1");
		session.finalizeRun("run-1", { ok: true, answer: "truncated summary" });
		expect(session.assistantFor("run-1")?.text).toBe("truncated summary");
		const late = session.appendDelta("run-1", 1, "the real streamed text");
		expect(late.amended).toBe(true);
		expect(late.block.text).toBe("the real streamed text");
		// Only the first late delta replaces; the rest accumulate normally.
		session.appendDelta("run-1", 2, " continues");
		expect(session.bufferFor("run-1")).toBe("the real streamed text continues");
	});

	test("completed arriving before started keeps the answer", () => {
		const session = new SessionStore("s");
		session.activeRunId = "run-1";
		session.busy = true;
		const block = session.finalizeRun("run-1", { ok: true, answer: "quick reply" });
		expect(block).toBeDefined();
		expect(block?.text).toBe("quick reply");
		expect(block?.status).toBe("done");
		expect(session.blocks.filter((b) => b.kind === "assistant")).toHaveLength(1);
		// A `started` event arriving afterwards must reuse that same block.
		expect(session.ensureAssistant("run-1")).toBe(block!);
	});

	test("a run that produced nothing at all creates no block", () => {
		const session = new SessionStore("s");
		session.activeRunId = "run-1";
		session.busy = true;
		expect(session.finalizeRun("run-1", { ok: false, answer: "" })).toBeUndefined();
		expect(session.blocks).toHaveLength(0);
		expect(session.busy).toBe(false);
	});

	test("finalizing an unknown run clears busy without a block", () => {
		const session = new SessionStore("s");
		session.activeRunId = "run-9";
		session.busy = true;
		expect(session.finalizeRun("run-9", { ok: true })).toBeUndefined();
		expect(session.busy).toBe(false);
	});
});

describe("SessionStore tools", () => {
	test("phases collapse onto one block per action id", () => {
		const session = new SessionStore("s");
		const started = session.upsertTool(
			{ id: "a1", kind: "command", title: "bash", detail: null },
			"started",
			{ runId: "run-1" },
		);
		const completed = session.upsertTool(
			{ id: "a1", kind: "command", title: "bash", detail: null },
			"completed",
			{ runId: "run-1", ok: true, message: "exit 0" },
		);
		expect(completed).toBe(started);
		expect(completed.phase).toBe("completed");
		expect(completed.ok).toBe(true);
		expect(completed.message).toBe("exit 0");
		expect(session.blocks.filter((b) => b.kind === "tool")).toHaveLength(1);
	});

	test("a phase never regresses once the action completed", () => {
		const session = new SessionStore("s");
		const action = { id: "a1", kind: "command", title: "bash", detail: null };
		session.upsertTool(
			{ ...action, detail: { name: "bash", args: { command: "ls" } } },
			"started",
			{
				runId: "run-1",
			},
		);
		const completed = session.upsertTool(
			{ ...action, detail: { name: "bash", args: { command: "ls" } as unknown, result: "a\nb" } },
			"completed",
			{ runId: "run-1", ok: true, message: "exit 0" },
		);

		// A reconnect redelivers the opening frames. Applying them would regress a
		// finalized card back to running and, worse, replace its result with the
		// pre-result detail — rewriting rows that may already be in scrollback.
		for (const phase of ["started", "updated"] as const) {
			const replayed = session.upsertTool(
				{ ...action, detail: { name: "bash", args: { command: "ls" } } },
				phase,
				{ runId: "run-1", ok: null, message: null },
			);
			expect(replayed).toBe(completed);
			expect(replayed.phase).toBe("completed");
			expect(replayed.ok).toBe(true);
			expect(replayed.message).toBe("exit 0");
			expect(replayed.detail?.result).toBe("a\nb");
		}
		expect(session.blocks.filter((b) => b.kind === "tool")).toHaveLength(1);
	});

	test("a late completed frame may still correct a completed action", () => {
		const session = new SessionStore("s");
		const action = { id: "a1", kind: "command", title: "bash", detail: null };
		session.upsertTool(action, "completed", { runId: "run-1", ok: true });
		const corrected = session.upsertTool(action, "completed", {
			runId: "run-1",
			ok: false,
			message: "actually it failed",
		});
		expect(corrected.ok).toBe(false);
		expect(corrected.message).toBe("actually it failed");
	});

	test("actions without an id fall back to a run+title key", () => {
		const session = new SessionStore("s");
		session.upsertTool({ id: null, kind: "tool", title: "read", detail: null }, "started", {
			runId: "run-1",
		});
		session.upsertTool({ id: null, kind: "tool", title: "read", detail: null }, "completed", {
			runId: "run-1",
		});
		expect(session.blocks.filter((b) => b.kind === "tool")).toHaveLength(1);
	});
});

describe("SessionStore unread", () => {
	test("counts blocks arriving while unfocused, except the user's own", () => {
		const session = new SessionStore("s");
		session.appendDelta("run-1", 1, "hi");
		session.addNotice("something happened");
		session.addUser("typed elsewhere");
		expect(session.unread).toBe(2);
		session.markRead();
		expect(session.unread).toBe(0);
	});

	test("a focused session never accrues unread", () => {
		const session = new SessionStore("s");
		session.focused = true;
		session.appendDelta("run-1", 1, "hi");
		session.addNotice("note");
		expect(session.unread).toBe(0);
	});
});
