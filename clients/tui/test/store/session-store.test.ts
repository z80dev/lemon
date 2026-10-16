import { beforeEach, describe, expect, spyOn, test } from "bun:test";
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

	test("text after a tool starts a new segment below the tool without duplicating prior text", () => {
		const session = new SessionStore("s");
		const first = session.appendDelta("run", 1, "I will inspect.").block;
		session.upsertTool(
			{ id: "read-1", kind: "tool", title: "read", detail: { name: "read" } },
			"completed",
			{ runId: "run" },
		);
		const replay = session.appendDelta("run", 1, "I will inspect.");
		expect(replay.accepted).toBe(false);
		expect(session.blocks).toHaveLength(2);
		const last = session.appendDelta("run", 2, "The answer.").block;
		session.finalizeRun("run", { ok: true, answer: "I will inspect.The answer." });
		expect(session.blocks.map((block) => block.kind)).toEqual(["assistant", "tool", "assistant"]);
		expect(first.text).toBe("I will inspect.");
		expect(first.status).toBe("done");
		expect(last.text).toBe("The answer.");
		expect(last.status).toBe("done");
		expect(session.bufferFor("run")).toBe("I will inspect.The answer.");
	});

	test("completion before a late post-tool delta preserves chronological segments", () => {
		const session = new SessionStore("s");
		session.appendDelta("run", 1, "Before");
		session.addNotice("tool boundary");
		session.finalizeRun("run", { ok: true });
		const late = session.appendDelta("run", 2, "After");
		expect(late.amended).toBe(true);
		expect(late.block.text).toBe("After");
		expect(late.block.status).toBe("done");
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

	test("the daemon's turn report still lands after a client-side interrupt", () => {
		const session = new SessionStore("s");
		session.appendDelta("run-1", 1, "half");
		session.markInterrupted("run-1");
		const block = session.finalizeRun("run-1", {
			ok: false,
			interrupted: true,
			turn: { durationMs: 1200, model: "m" },
		});
		expect(block?.status).toBe("aborted");
		expect(block?.turn).toEqual({ durationMs: 1200, model: "m" });
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

	test("freezes the observed terminal time for success, failure and cancellation", () => {
		let clock = 1000;
		const now = spyOn(Date, "now").mockImplementation(() => clock);
		try {
			for (const outcome of ["success", "failure", "cancelled"]) {
				clock = 1000;
				const session = new SessionStore("s");
				const action = { id: outcome, kind: "tool", title: "read", detail: null };
				const block = session.upsertTool(action, "started");
				expect(block.at).toBe(1000);
				expect(block.completedAt).toBeUndefined();

				clock = 1020;
				session.upsertTool(action, "updated");
				expect(block.at).toBe(1000);
				expect(block.completedAt).toBeUndefined();

				clock = 1042;
				const terminal = {
					...action,
					detail: {
						name: "read",
						result: outcome,
						details: { cancelled: outcome === "cancelled" },
					},
				};
				session.upsertTool(terminal, "completed", { ok: outcome === "success" });
				expect(block.completedAt).toBe(1042);

				clock += 600_000;
				session.upsertTool(terminal, "completed", { ok: outcome === "success" });
				session.upsertTool(action, "started");
				session.upsertTool(action, "updated");
				expect(block.at).toBe(1000);
				expect(block.completedAt).toBe(1042);
			}
		} finally {
			now.mockRestore();
		}
	});

	test("an already-completed receipt never acquires an invented duration on replay", () => {
		let clock = 1000;
		const now = spyOn(Date, "now").mockImplementation(() => clock);
		try {
			const session = new SessionStore("s");
			const action = { id: "receipt", kind: "tool", title: "read", detail: null };
			const block = session.upsertTool(action, "completed", { ok: true });
			expect(block.completedAt).toBeUndefined();
			clock += 600_000;
			session.upsertTool(action, "started");
			session.upsertTool(action, "completed", { ok: false });
			expect(block.completedAt).toBeUndefined();
		} finally {
			now.mockRestore();
		}
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

describe("SessionStore reasoning", () => {
	const thought = (text: string) => ({
		id: "lemon.reasoning.0.1",
		kind: "reasoning",
		title: "reasoning",
		detail: { reasoning: { text, source: "lemon_reasoning" } },
	});

	test("each phase replaces the block's text in place", () => {
		const session = new SessionStore("s");
		const first = session.upsertReasoning(thought("checking"), "updated", { runId: "r" });
		const second = session.upsertReasoning(thought("checking the seam"), "completed", {
			runId: "r",
		});
		expect(second).toBe(first);
		expect(second.text).toBe("checking the seam");
		expect(session.blocks.filter((block) => block.kind === "reasoning")).toHaveLength(1);
	});

	test("a replayed update cannot reopen a completed thought", () => {
		const session = new SessionStore("s");
		session.upsertReasoning(thought("done thinking"), "completed", { runId: "r" });
		const replay = session.upsertReasoning(thought("half"), "updated", { runId: "r" });
		expect(replay.phase).toBe("completed");
		expect(replay.text).toBe("done thinking");
	});

	test("finalizing the run completes its open thoughts, and only its own", () => {
		const session = new SessionStore("s");
		const mine = session.upsertReasoning(thought("mine"), "updated", { runId: "r1" });
		const other = session.upsertReasoning(
			{ ...thought("other"), id: "lemon.reasoning.0.2" },
			"updated",
			{ runId: "r2" },
		);
		session.finalizeRun("r1", { ok: true });
		expect(mine.phase).toBe("completed");
		expect(other.phase).toBe("updated");
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

	test("a sessions.context measurement wins until the next run reports usage", () => {
		const session = new SessionStore("s");
		session.applyUsage({ contextTokens: 5_000 });
		session.applyContextMeasurement(45_210, 200_000);
		expect(session.contextTokens).toBe(45_210);
		expect(session.contextMeasurement).toEqual({ tokens: 45_210, window: 200_000 });
		session.applyUsage({ contextTokens: 47_000 });
		expect(session.contextTokens).toBe(47_000);
		expect(session.contextMeasurement).toBeUndefined();
	});

	test("a model change keeps the measured total but drops its window", () => {
		const session = new SessionStore("s");
		session.setModel({ model: "claude-sonnet-4-5" }, "run");
		session.applyContextMeasurement(1_000, 200_000);
		session.setModel({ model: "gpt-4o" }, "local");
		expect(session.contextMeasurement).toEqual({ tokens: 1_000, window: undefined });
	});

	test("ignores nonsense measurements and forgets them on reset", () => {
		const session = new SessionStore("s");
		session.applyContextMeasurement(-1, 200_000);
		session.applyContextMeasurement(Number.NaN, 200_000);
		expect(session.contextMeasurement).toBeUndefined();
		session.applyContextMeasurement(0, null);
		expect(session.contextTokens).toBe(0);
		session.resetTranscript();
		expect(session.contextMeasurement).toBeUndefined();
	});
});

test("a notice seals text layout without hiding the later interrupt outcome", () => {
	const session = new SessionStore("s");
	session.activeRunId = "run";
	session.busy = true;
	session.appendDelta("run", 1, "partial answer");
	session.addNotice("aborting");
	const block = session.markInterrupted("run");
	expect(block?.status).toBe("aborted");
	expect(block?.text).toBe("partial answer");
	session.finalizeRun("run", { ok: true });
	expect(block?.status).toBe("aborted");
});

test("replacing history clears synthetic run indexes as well as visible blocks", () => {
	const session = new SessionStore("s");
	session.appendDelta("history:entry", Number.NaN, "abandoned text");
	session.finalizeRun("history:entry", { ok: true });
	session.resetTranscript();
	session.appendDelta("history:entry", Number.NaN, "active text");
	session.finalizeRun("history:entry", { ok: true });
	expect(session.blocks).toHaveLength(1);
	expect(session.assistantFor("history:entry")?.text).toBe("active text");
});

describe("SessionStore cumulative cost", () => {
	test("sums run costs, never invents zero, and marks missing costs partial", () => {
		const session = new SessionStore("s");
		session.addRunCost("r1", { totalTokens: 5 });
		expect(session.sessionCostUsd).toBeUndefined();
		expect(session.sessionCostPartial).toBe(true);

		const fresh = new SessionStore("t");
		fresh.addRunCost("r1", { costUsd: 0.25 });
		fresh.addRunCost("r2", { costUsd: 0.5 });
		expect(fresh.sessionCostUsd).toBeCloseTo(0.75);
		expect(fresh.sessionCostPartial).toBe(false);
		fresh.addRunCost("r3", { costUsd: null });
		expect(fresh.sessionCostUsd).toBeCloseTo(0.75);
		expect(fresh.sessionCostPartial).toBe(true);
	});

	test("counts each run once", () => {
		const session = new SessionStore("s");
		session.addRunCost("r1", { costUsd: 0.25 });
		session.addRunCost("r1", { costUsd: 0.25 });
		session.addRunCost("r2", {});
		session.addRunCost("r2", { costUsd: 9 });
		expect(session.sessionCostUsd).toBeCloseTo(0.25);
		expect(session.costedRunCount).toBe(2);
	});

	test("a terminal run seen only in a snapshot is partial until its completion is counted", () => {
		const session = new SessionStore("s");
		session.noteTerminalRun("r1");
		expect(session.sessionCostPartial).toBe(true);
		session.addRunCost("r1", { costUsd: 0.1 });
		expect(session.sessionCostPartial).toBe(false);
		session.noteTerminalRun("r1");
		expect(session.sessionCostPartial).toBe(false);
	});

	test("unobserved history keeps the total a lower bound", () => {
		const session = new SessionStore("s");
		session.markCostUnobserved();
		session.addRunCost("r1", { costUsd: 0.25 });
		expect(session.sessionCostUsd).toBeCloseTo(0.25);
		expect(session.sessionCostPartial).toBe(true);
	});

	test("the daemon ledger seeds only a positive amount, and only while quiescent", () => {
		const zero = new SessionStore("a");
		zero.seedPriorCost(0, true);
		expect(zero.sessionCostUsd).toBeUndefined();
		expect(zero.sessionCostPartial).toBe(false);

		const seeded = new SessionStore("b");
		seeded.seedPriorCost(1.5, true);
		expect(seeded.sessionCostUsd).toBeCloseTo(1.5);
		expect(seeded.sessionCostPartial).toBe(true);
		seeded.addRunCost("r1", { costUsd: 0.25 });
		expect(seeded.sessionCostUsd).toBeCloseTo(1.75);

		const busy = new SessionStore("c");
		busy.seedPriorCost(1.5, false);
		expect(busy.sessionCostUsd).toBeUndefined();
		expect(busy.sessionCostPartial).toBe(true);

		const counted = new SessionStore("d");
		counted.addRunCost("r1", { costUsd: 0.25 });
		counted.seedPriorCost(1.5, true);
		expect(counted.sessionCostUsd).toBeCloseTo(0.25);
	});
});
