import { afterEach, beforeEach, expect, test } from "bun:test";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import type { ControlPlaneMethods } from "../../src/protocol/methods.ts";
import {
	parseSubagentSend,
	parseSubagents,
	type Subagent,
	type SubagentSendResult,
} from "../../src/protocol/subagents.ts";
import { TaskTreeController } from "../../src/ui/controllers/task-tree-controller.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";

const ENTER = "\r";
const ESC = "\u001b";
const DOWN = "\u001b[B";

const controllers: TaskTreeController[] = [];
beforeEach(() => initTheme({ colorLevel: 0 }));
afterEach(() => {
	for (const controller of controllers.splice(0)) controller.dispose();
	resetTheme();
});

const ROSTER: Subagent[] = parseSubagents({
	agents: [
		{
			taskId: "lead",
			status: "running",
			depth: 0,
			name: "Lead",
			agent: "task",
			description: "Coordinate the parser work",
			model: "anthropic/claude-sonnet-4-5",
			activity: "reading lib/parser.ex",
			startedAtMs: 1_000,
			usage: { tokens: 12_000, costUsd: 0.04, requests: 3 },
			contextPercent: 21,
			messaging: true,
			cancellable: true,
		},
		{
			taskId: "nested",
			status: "idle",
			depth: 1,
			parentTaskId: "lead",
			name: "Scout",
			agent: "scout",
			startedAtMs: 1_500,
			completedAtMs: 5_000,
			usage: { requests: 2 },
			messaging: true,
			cancellable: true,
		},
		{
			taskId: "sleeper",
			status: "parked",
			depth: 0,
			name: "Reviewer",
			startedAtMs: 500,
			completedAtMs: 2_000,
			messaging: true,
			cancellable: true,
		},
		{ taskId: "done", status: "completed", depth: 0, name: "Finished", startedAtMs: 100 },
		{ taskId: "bad", status: "exploded" },
	],
});

interface Calls {
	sent: Array<{ sessionKey: string; taskId: string; message: string }>;
	cancelled: string[];
	transcripts: string[];
}

function hub(
	options: {
		roster?: Subagent[];
		online?: boolean;
		supports?: (method: string) => boolean;
		receipt?: SubagentSendResult;
		/** Fixed text, a read failure, or text read afresh on every call. */
		transcript?: string | Error | (() => string);
		transcriptStatus?: string;
	} = {},
) {
	let now = 10_000;
	const calls: Calls = { sent: [], cancelled: [], transcripts: [] };
	const notices: string[] = [];
	let roster = options.roster ?? ROSTER;
	const methods = {
		supports: options.supports ?? (() => true),
		subagentsList: async ({ sessionKey }: { sessionKey: string }) =>
			sessionKey === "chat" ? roster : [],
		subagentsTranscript: async ({ taskId }: { taskId: string }) => {
			calls.transcripts.push(taskId);
			if (options.transcript instanceof Error) throw options.transcript;
			const text =
				typeof options.transcript === "function" ? options.transcript() : options.transcript;
			return {
				taskId,
				status: options.transcriptStatus ?? "running",
				text: text ?? `# Task ${taskId}\nStatus: running\n\nline one`,
				truncated: false,
			};
		},
		subagentsSend: async (params: { sessionKey: string; taskId: string; message: string }) => {
			calls.sent.push(params);
			return (
				options.receipt ??
				parseSubagentSend({ accepted: true, delivery: "injected", retrySafe: true }, params.taskId)
			);
		},
		subagentsCancel: async ({ taskId }: { taskId: string }) => {
			calls.cancelled.push(taskId);
			return { cancelled: true };
		},
	} as unknown as ControlPlaneMethods;
	const tree = new TaskTreeController({
		methods,
		online: () => options.online ?? true,
		notice: (text) => notices.push(text),
		now: () => now,
		pollMs: 60_000,
		requestRender() {},
	});
	controllers.push(tree);
	tree.setSession("chat");
	tree.panel.focused = true;
	return {
		tree,
		calls,
		notices,
		text: (width = 200) => tree.panel.render(width).join("\n"),
		setNow: (value: number) => {
			now = value;
		},
		setRoster: (next: Subagent[]) => {
			roster = next;
		},
		keys: (...keys: string[]) => {
			for (const key of keys) tree.panel.handleInput(key);
		},
	};
}

async function settle(): Promise<void> {
	for (let index = 0; index < 5; index++) await Promise.resolve();
}

test("the daemon roster is authoritative: lineage, idle and parked agents, model and usage", async () => {
	const { tree, text } = hub();
	tree.ingest({
		type: "tool_use",
		runId: "parent-run",
		sessionKey: "chat",
		phase: "completed",
		action: {
			id: "launch",
			kind: "subagent",
			title: "launch",
			detail: { name: "task", details: { task_id: "nested", status: "completed", output: "ok" } },
		},
	});
	tree.toggle();
	await tree.refresh(false);
	expect(tree.store.items("chat")).toHaveLength(4);
	// A completed first turn followed by an idle live session is not terminal.
	expect(tree.store.find("chat", "nested")?.status).toBe("idle");
	const shown = text();
	expect(shown).toContain(
		"agents · 1 running · 1 idle · 1 parked · 1 done · 12k tok $0.04 5 req · tree",
	);
	expect(shown).toContain(
		"running 9s · Lead @task · lead · anthropic/claude-sonnet-4-5 · 12k tok $0.04 3 req",
	);
	expect(shown).toContain("reading lib/parser.ex");
	expect(shown).toContain("└─ idle 5s · Scout @scout · nested · 2 req");
	expect(shown).toContain("parked 8s · Reviewer · sleeper");
	expect(shown).toContain("task lead · ctx 21% · Coordinate the parser work");
	expect(shown.indexOf("Lead")).toBeLessThan(shown.indexOf("Scout"));
	expect(shown.indexOf("Scout")).toBeLessThan(shown.indexOf("Reviewer"));
});

test("a woken agent runs again and t switches to the operational flat order", async () => {
	const { tree, text, setRoster, keys } = hub();
	tree.toggle();
	await tree.refresh(false);
	setRoster(
		ROSTER.map((agent) =>
			agent.taskId === "sleeper"
				? { ...agent, status: "running", completedAtMs: undefined }
				: agent,
		),
	);
	await tree.refresh(false);
	expect(tree.store.find("chat", "sleeper")?.status).toBe("running");
	expect(tree.store.find("chat", "sleeper")?.finishedAt).toBeUndefined();
	keys("t");
	const flat = text();
	expect(flat).toContain("· flat");
	expect(flat).not.toContain("└─");
	const order = ["Lead", "Reviewer", "Scout", "Finished"].map((name) => flat.indexOf(name));
	expect(order).toEqual([...order].sort((a, b) => a - b));
});

test("filter narrows by id or name; escape clears it before closing the hub", async () => {
	const { tree, text, keys } = hub();
	tree.toggle();
	await tree.refresh(false);
	keys("/", "s", "c", "o");
	expect(text()).toContain("/sco▏");
	expect(text()).toContain("Scout");
	expect(text()).not.toContain("Reviewer");
	keys(ENTER);
	expect(tree.panel.selected?.taskId).toBe("nested");
	keys(ESC);
	expect(tree.panel.filter).toBe("");
	expect(tree.panel.visible).toBe(true);
	keys("/", "z", "z", "z");
	expect(text()).toContain("No agents match.");
	keys(ESC, ESC);
	expect(tree.panel.visible).toBe(false);
});

test("Enter opens the transcript; typed messages steer, follow up or revive by status", async () => {
	const { tree, calls, notices, text, keys } = hub({
		transcript: "# Task lead\nStatus: running\n\u001b[31mred\u001b[0m and\u0007 output",
	});
	tree.toggle();
	await tree.refresh(false);
	keys(ENTER);
	await settle();
	expect(calls.transcripts).toEqual(["lead"]);
	expect(tree.panel.view).toBe("transcript");
	let shown = text();
	expect(shown).toContain("agents › Lead @task · lead · running 9s · transcript");
	expect(shown).toContain("red and output");
	expect(shown).not.toContain("\u001b");
	expect(shown).not.toContain("\u0007");
	expect(shown).toContain("steer › ▏");
	keys(..."focus on tests");
	expect(text()).toContain("steer › focus on tests▏");
	keys(ENTER);
	await settle();
	expect(calls.sent).toEqual([{ sessionKey: "chat", taskId: "lead", message: "focus on tests" }]);
	shown = text();
	expect(shown).toContain("steer › ▏");
	expect(shown).toContain("steered lead");
	expect(notices).toContain("agents: steered lead");
	for (const width of [1, 10, 40, 80]) {
		for (const row of tree.panel.render(width))
			expect(visibleWidth(row)).toBeLessThanOrEqual(width);
	}
	keys(ESC);
	expect(tree.panel.view).toBe("roster");
	keys(DOWN, ENTER);
	await settle();
	expect(text()).toContain("follow up › ");
	keys(ESC, DOWN, ENTER);
	await settle();
	expect(text()).toContain("revive › ");
});

test("an unknown outcome keeps the message for review and is never resent automatically", async () => {
	const { tree, calls, text, keys } = hub({
		receipt: parseSubagentSend({ delivery: "outcome_unknown", accepted: false }, "lead"),
	});
	tree.toggle();
	await tree.refresh(false);
	keys(ENTER);
	await settle();
	keys(..."maybe");
	keys(ENTER);
	await settle();
	expect(calls.sent).toHaveLength(1);
	const shown = text();
	expect(shown).toContain("steer › maybe▏");
	expect(shown).toContain("may or may not have been delivered");
});

test("x cancels only after confirmation and finished agents cannot be cancelled or messaged", async () => {
	const { tree, calls, text, keys } = hub();
	tree.toggle();
	await tree.refresh(false);
	keys("x");
	expect(text()).toContain("press x again to cancel Lead — cancellation is final");
	expect(calls.cancelled).toEqual([]);
	keys(DOWN, "x");
	expect(calls.cancelled).toEqual([]);
	keys("x");
	await settle();
	expect(calls.cancelled).toEqual(["nested"]);
	expect(text()).toContain("cancelled nested; its transcript stays readable");
	keys(DOWN, DOWN, "x");
	expect(text()).toContain("Finished has already finished");
	keys(ENTER);
	await settle();
	expect(text()).toContain("this agent can no longer be messaged");
	keys("h", "i");
	expect(text()).toContain("Finished can no longer be messaged");
	expect(calls.sent).toEqual([]);
});

test("offline or older daemons never send, and transcript failures are shown", async () => {
	const offline = hub({ online: false, transcript: new Error("Subagent not found") });
	offline.tree.toggle();
	await offline.tree.refresh(false);
	offline.keys(ENTER);
	await settle();
	expect(offline.text()).toContain("transcript unavailable: Subagent not found");
	offline.keys(..."hello", ENTER);
	await settle();
	expect(offline.calls.sent).toEqual([]);
	expect(offline.text()).toContain("offline — message not sent");
	expect(offline.text()).toContain("hello");

	const older = hub({ supports: () => false });
	older.tree.toggle();
	await older.tree.refresh(true);
	expect(older.tree.store.items("chat")).toEqual([]);
	expect(older.text()).toContain("daemon does not support subagents.list");
});

test("the open transcript stops re-reading once final, or after three failed reads until reopened", async () => {
	const done = hub({ transcriptStatus: "completed" });
	done.tree.toggle();
	await done.tree.refresh(false);
	done.keys(ENTER);
	await settle();
	await done.tree.refresh(false);
	await done.tree.refresh(false);
	// One read observed the final status; nothing newer can arrive.
	expect(done.calls.transcripts).toEqual(["lead"]);

	const failing = hub({ transcript: new Error("boom") });
	failing.tree.toggle();
	await failing.tree.refresh(false);
	failing.keys(ENTER);
	await settle();
	for (let index = 0; index < 4; index++) await failing.tree.refresh(false);
	expect(failing.calls.transcripts).toHaveLength(3);
	expect(failing.text()).toContain("transcript unavailable: boom");
	expect(failing.text()).toContain("transcript reads stopped after 3 failures");
	failing.keys(ESC, ENTER);
	await settle();
	expect(failing.calls.transcripts).toHaveLength(4);
});

test("a transcript follows its newest line until scrolled up, and again from the bottom", async () => {
	let lines = 40;
	const { tree, text, keys } = hub({
		transcript: () => Array.from({ length: lines }, (_, index) => `row ${index}`).join("\n"),
	});
	tree.toggle();
	await tree.refresh(false);
	keys(ENTER);
	await settle();
	expect(text()).toContain("row 39");
	expect(text()).toContain("following");
	keys("\u001b[A");
	lines = 41;
	await tree.refresh(false);
	expect(text()).not.toContain("row 40");
	expect(text()).not.toContain("following");
	keys("\u001b[F");
	expect(text()).toContain("row 40");
	lines = 42;
	await tree.refresh(false);
	expect(text()).toContain("row 41");
	keys("\u001b[H");
	expect(text()).toContain("row 0");
	expect(text()).not.toContain("row 41");
});

test("Tern describes agents as native nodes and the transcript with its message line", async () => {
	const { tree, keys } = hub();
	tree.toggle();
	await tree.refresh(false);
	const roster = JSON.stringify(tree.panel.describe());
	expect(roster).toContain('"status":"idle"');
	expect(roster).toContain('"status":"parked"');
	expect(roster).toContain('"model":"anthropic/claude-sonnet-4-5"');
	expect(roster).toContain('"tokens":12000');
	expect(roster).toContain('"depth":1');
	keys(ENTER);
	await settle();
	keys("o", "k");
	const transcript = JSON.stringify(tree.panel.describe());
	expect(transcript).toContain("line one");
	expect(transcript).toContain("steer › ");
	expect(transcript).toContain('"ok"');
});

test("the wire parser drops malformed rows and an unrecognised receipt is an unknown outcome", () => {
	expect(ROSTER.map((agent) => agent.taskId)).toEqual(["lead", "nested", "sleeper", "done"]);
	expect(() => parseSubagents({})).toThrow();
	expect(parseSubagentSend({ ok: true }, "lead")).toEqual({
		taskId: "lead",
		accepted: false,
		delivery: "outcome_unknown",
		retrySafe: false,
	});
});
