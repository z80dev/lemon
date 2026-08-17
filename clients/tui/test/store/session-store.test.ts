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

describe("SessionStore model precedence", () => {
	test("a detail fetch fills in a session that knows nothing", () => {
		const session = new SessionStore("s");
		const changed = session.setModel(
			{ model: "claude-sonnet-4", provider: "anthropic", contextWindow: 200_000 },
			"detail",
		);
		expect(changed).toBe(true);
		expect(session.model).toBe("claude-sonnet-4");
		expect(session.provider).toBe("anthropic");
		expect(session.contextWindow).toBe(200_000);
		expect(session.modelSource).toBe("detail");
	});

	test("a detail fetch never overwrites a local pin", () => {
		const session = new SessionStore("s");
		session.setModel({ model: "gpt-4o" }, "local");
		const changed = session.setModel({ model: "claude-sonnet-4" }, "detail");
		expect(changed).toBe(false);
		expect(session.model).toBe("gpt-4o");
		expect(session.modelSource).toBe("local");
	});

	test("a run overrides a local pin the daemon evidently did not honour", () => {
		const session = new SessionStore("s");
		session.setModel({ model: "gpt-4o" }, "local");
		session.setModel({ model: "claude-sonnet-4", provider: "anthropic" }, "run");
		expect(session.model).toBe("claude-sonnet-4");
		expect(session.provider).toBe("anthropic");
		expect(session.modelSource).toBe("run");
	});

	test("a later local pin wins again after a run reported one", () => {
		const session = new SessionStore("s");
		session.setModel({ model: "claude-sonnet-4" }, "run");
		session.setModel({ model: "gpt-4o" }, "local");
		expect(session.model).toBe("gpt-4o");
		expect(session.modelSource).toBe("local");
	});

	test("a detail fetch also never overwrites what a run reported", () => {
		const session = new SessionStore("s");
		session.setModel({ model: "claude-sonnet-4" }, "run");
		session.setModel({ model: "gpt-4o", contextWindow: 128_000 }, "detail");
		expect(session.model).toBe("claude-sonnet-4");
		expect(session.contextWindow).toBeUndefined();
	});

	test("re-naming the same model keeps the provider and window already learned", () => {
		const session = new SessionStore("s");
		session.setModel(
			{ model: "claude-sonnet-4", provider: "anthropic", contextWindow: 200_000 },
			"run",
		);
		// `agent completed` names the model without re-stating either.
		session.setModel({ model: "claude-sonnet-4" }, "run");
		expect(session.provider).toBe("anthropic");
		expect(session.contextWindow).toBe(200_000);
	});

	test("a different model drops the previous model's provider and window", () => {
		const session = new SessionStore("s");
		session.setModel(
			{ model: "claude-sonnet-4", provider: "anthropic", contextWindow: 200_000 },
			"run",
		);
		session.setModel({ model: "gpt-4o" }, "run");
		expect(session.provider).toBeUndefined();
		expect(session.contextWindow).toBeUndefined();
	});

	test("an event with no model at all changes nothing", () => {
		const session = new SessionStore("s");
		session.setModel({ model: "gpt-4o" }, "local");
		expect(session.setModel({ model: null }, "run")).toBe(false);
		expect(session.model).toBe("gpt-4o");
	});

	test("clearing the model is a local gesture only", () => {
		const session = new SessionStore("s");
		session.setModel({ model: "gpt-4o" }, "local");
		expect(session.setModel({ model: undefined }, "local")).toBe(true);
		expect(session.model).toBeUndefined();
	});
});

describe("SessionStore context tokens", () => {
	test("prefers the daemon's own context figure", () => {
		const session = new SessionStore("s");
		session.applyUsage({ inputTokens: 10, cacheReadTokens: 20, contextTokens: 999 });
		expect(session.contextTokens).toBe(999);
	});

	test("adds cache reads and writes to the input side", () => {
		const session = new SessionStore("s");
		session.applyUsage({ inputTokens: 1_000, cacheReadTokens: 8_000, cacheWriteTokens: 500 });
		expect(session.contextTokens).toBe(9_500);
	});

	test("excludes output, which is not part of the context that was sent", () => {
		const session = new SessionStore("s");
		session.applyUsage({ inputTokens: 1_000, outputTokens: 4_000 });
		expect(session.contextTokens).toBe(1_000);
	});

	test("refuses to treat a cumulative run total as a context size", () => {
		const session = new SessionStore("s");
		// Engines report totalTokens across every turn of the run — a live run showed
		// 86k total against a 21k context — so it cannot stand in for the input side.
		session.applyUsage({ totalTokens: 86_354 });
		expect(session.contextTokens).toBeUndefined();
	});

	test("a run that reported nothing leaves the last known counts alone", () => {
		const session = new SessionStore("s");
		session.applyUsage({ contextTokens: 5_000 });
		session.applyUsage(null);
		expect(session.contextTokens).toBe(5_000);
	});

	test("is undefined before any run has completed", () => {
		expect(new SessionStore("s").contextTokens).toBeUndefined();
	});
});
