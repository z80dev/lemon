import { describe, expect, test } from "bun:test";
import {
	OMP_DISCOVERED_FIXTURES,
	OMP_SESSION_FIXTURES,
	ompSessionWire,
} from "../../src/dev/fixtures/omp-fixtures.ts";
import { defaultRegistry } from "../../src/formatters/index.ts";
import { ompFormatter, ompTodoProgress, ompUsageText } from "../../src/formatters/omp.ts";
import { parseOmpSession } from "../../src/protocol/omp.ts";
import { TERMINAL_CONTROLS } from "../helpers/memory-terminal.ts";

function all(output: { summary: string; details: string[] }): string {
	return [output.summary, ...output.details].join("\n");
}

describe("omp formatter", () => {
	test("is registered for the omp tool", () => {
		expect(defaultRegistry.getFormatter("omp")).toBe(ompFormatter);
	});

	test("args: action plus target or prompt preview", () => {
		expect(
			ompFormatter.formatArgs({ action: "start", prompt: "Fix the build\nthen ship" }).summary,
		).toBe("start: Fix the build then ship");
		expect(ompFormatter.formatArgs({ action: "wait", id: "omp_a", timeout_seconds: 60 })).toEqual({
			summary: "wait omp_a",
			details: ["action: wait", "id: omp_a", "timeout_seconds: 60"],
		});
		expect(
			ompFormatter.formatArgs({ action: "send", id: "omp_a", message: "go", mode: "follow_up" })
				.summary,
		).toBe("send omp_a: go");
		expect(ompFormatter.formatArgs({ action: "resume", omp_session_id: "01a1" }).summary).toBe(
			"resume 01a1",
		);
	});

	test("session result: header, status, activity, todos, usage and collapsed result", () => {
		const output = ompFormatter.formatResult(
			{
				content: [{ type: "text", text: "summary" }],
				details: { action: "wait", session: ompSessionWire() },
			},
			{ action: "wait", id: "omp_3f9a1c2b7d4e" },
		);
		expect(output.summary).toBe("wait · Fix the flaky reconnect test · running · todos 2/4");
		const text = all(output);
		expect(text).toContain("activity: Running bash — bun test test/protocol/ws.test.ts");
		expect(text).toContain("▶ bash — Re-running the reconnect suite");
		expect(text).toContain("usage: 41k tok · $0.0018 · ctx 18%");
		expect(text).toContain("latest:");
		expect(output.isError).toBe(false);
	});

	test("long result text is collapsed to a few lines", () => {
		const result = Array.from({ length: 20 }, (_, index) => `line ${index}`).join("\n");
		const output = ompFormatter.formatResult({
			details: { action: "status", session: ompSessionWire({ status: "idle", result }) },
		});
		expect(output.details).toContain("line 5");
		expect(output.details).not.toContain("line 6");
		expect(output.details.some((line) => /more\)/.test(line))).toBe(true);
	});

	test("partial updates format like results", () => {
		const first = ompFormatter.formatPartial?.({
			details: { action: "wait", session: ompSessionWire({ todos: [] }) },
		});
		const later = ompFormatter.formatPartial?.({
			details: {
				action: "wait",
				session: ompSessionWire({ status: "idle", lastTurn: "completed", todos: [] }),
			},
		});
		expect(first?.summary).toContain("running");
		expect(later?.summary).toContain("idle · completed");
	});

	test("list and discover", () => {
		const list = ompFormatter.formatResult({
			details: { action: "list", sessions: OMP_SESSION_FIXTURES },
		});
		expect(list.summary).toBe("list · 3 sessions (1 running)");
		expect(list.details).toHaveLength(3);
		const discover = ompFormatter.formatResult({
			details: { action: "discover", sessions: OMP_DISCOVERED_FIXTURES },
		});
		expect(discover.summary).toBe("discover · 2 sessions");
		expect(discover.details[1]).toContain("live omp_3f9a1c2b7d4e");
	});

	test("errors and malformed details fall back to the result text", () => {
		const output = ompFormatter.formatResult({
			content: [{ type: "text", text: "omp send failed: not running" }],
			details: { action: "send", error: "not_running", session: "nope" },
			is_error: true,
		});
		expect(output).toEqual({
			summary: "omp send failed: not running",
			details: ["omp send failed: not running"],
			isError: true,
		});
		expect(ompFormatter.formatResult(null).summary).toBe("omp");
	});

	test("untrusted omp text is rendered without terminal controls", () => {
		const output = ompFormatter.formatResult({
			details: {
				action: "status",
				session: {
					...OMP_SESSION_FIXTURES[2],
					result: "done\u001b]8;;https://evil\u0007click\u001b]8;;\u0007\u0000\r\nbye",
				},
			},
		});
		const text = all(output);
		expect(text).not.toMatch(TERMINAL_CONTROLS);
		expect(text).toContain("Hostile title red");
		expect(text).toContain("error: provider error: rate limited");
		expect(text).toContain("doneclick");
	});

	test("batch workers, combined usage, reasons and per-task errors", () => {
		const details = {
			action: "start_many",
			sessions: [ompSessionWire()],
			usage: { totalTokens: 1234, cost: 0.25 },
			errors: [{ task: 1, error: "invalid_task", message: "bad\u001b[31m task" }],
			reason: "timeout",
		};
		const output = ompFormatter.formatResult({ details });
		expect(output.summary).toBe("start_many · 1 workers");
		expect(all(output)).toContain("todos 2/4");
		expect(all(output)).toContain("combined: 1.2k tok · $0.2500");
		expect(all(output)).toContain("task 2: invalid_task · bad task");
		expect(all(output)).toContain("wait: timeout");
		expect(ompFormatter.formatPartial?.({ details })).toEqual(output);
	});

	test("approvals, worktrees, children and configuration are plain text", () => {
		const output = ompFormatter.formatResult({
			details: {
				action: "configure",
				session: {
					...ompSessionWire(),
					pendingApprovals: [{ tool: "bash\u001b[31m" }],
					worktree: { branch: "worker", kept: true, dirty: true },
					subagents: [{ id: "child", status: "running", activity: "Reading files" }],
				},
			},
		});
		expect(output.summary).toContain("waiting for approval: bash");
		expect(all(output)).toContain("worktree: worker · kept · dirty");
		expect(all(output)).toContain("↳ child · running · Reading files");
		expect(all(output)).not.toMatch(TERMINAL_CONTROLS);
	});

	test("models, transcript tail, discovery metadata and continue arguments", () => {
		const models = ompFormatter.formatResult({
			details: {
				action: "models",
				models: [
					{ selector: "p/free", contextWindow: 32000, free: true },
					{ selector: "p/paid", costInput: 1, costOutput: 2 },
				],
			},
		});
		expect(all(models)).toContain("p/free · ctx 32k · FREE");
		expect(all(models)).toContain("$1/$2 per Mtok");
		const transcript = ompFormatter.formatResult({
			details: {
				action: "subagent",
				subagentId: "child",
				transcript: {
					messages: Array.from({ length: 50 }, (_, i) => ({
						role: "assistant",
						text: `message ${i}\u001b[31m`,
					})),
				},
			},
		});
		expect(all(transcript)).toContain("message 49");
		expect(all(transcript)).not.toContain("message 0");
		expect(all(transcript)).not.toMatch(TERMINAL_CONTROLS);
		expect(transcript.details.length).toBeLessThanOrEqual(24);
		const discover = ompFormatter.formatResult({
			details: {
				action: "discover",
				sessions: OMP_DISCOVERED_FIXTURES.map((row) => ({
					...row,
					source: "omp",
					interrupted: true,
					worktree: { branch: "worker" },
				})),
			},
		});
		expect(all(discover)).toContain("omp · interrupted · worker");
		expect(all(ompFormatter.formatArgs({ action: "resume", continue: true }))).toContain(
			"continue: true",
		);
	});

	test("shared helpers", () => {
		const session = parseOmpSession(ompSessionWire());
		if (!session) throw new Error("fixture");
		expect(ompTodoProgress(session.todos)).toBe("2/4");
		expect(ompTodoProgress([])).toBeUndefined();
		expect(ompUsageText({ ...session, usage: null, contextPercent: null })).toBeUndefined();
	});
});
