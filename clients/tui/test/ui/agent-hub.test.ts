import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import type { ChatHistoryMessage } from "../../src/protocol/types.ts";
import { TaskStore } from "../../src/store/task-store.ts";
import {
	formatElapsed,
	projectAgentHubRows,
	summarizeAgentHubRows,
} from "../../src/ui/agent-hub-rows.ts";
import { AgentHubComponent, transcriptLines } from "../../src/ui/components/agent-hub.ts";
import { TaskTreeController } from "../../src/ui/controllers/task-tree-controller.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";

const ESC = "\u001b";
const ENTER = "\r";
const DOWN = "\u001b[B";

beforeEach(() => initTheme({ colorLevel: 0 }));
afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

function message(
	id: string,
	role: string,
	content: string,
	extra: Partial<ChatHistoryMessage> = {},
): ChatHistoryMessage {
	return { id, role, content, timestampMs: null, ...extra };
}

describe("row projection", () => {
	test("keeps lineage order and depth, labels by description, freezes finished age", () => {
		const store = new TaskStore();
		store.upsert(
			"chat",
			[
				{
					taskId: "parent",
					runId: "run-parent",
					sessionId: "sess-parent",
					status: "running",
					description: "Survey the repo",
					agent: "scout",
					progress: "reading files",
				},
				{
					taskId: "child",
					runId: "run-child",
					parentRunId: "run-parent",
					status: "running",
				},
			],
			1000,
		);
		store.upsert("chat", [{ taskId: "child", status: "completed" }], 4000);
		const rows = projectAgentHubRows(store.tree("chat"), 9000);
		expect(rows.map((row) => [row.taskId, row.depth])).toEqual([
			["parent", 0],
			["child", 1],
		]);
		expect(rows[0]).toMatchObject({
			label: "Survey the repo",
			agent: "scout",
			status: "running",
			active: true,
			elapsedMs: 8000,
			progress: "reading files",
			sessionId: "sess-parent",
			runId: "run-parent",
		});
		// No description: the id is the label. Finished at 4000, so 9000 doesn't age it.
		expect(rows[1]).toMatchObject({ label: "child", active: false, elapsedMs: 3000 });
		expect(rows[1]!.sessionId).toBeUndefined();
	});

	test("an unknown outcome has no elapsed time and counts as neither done nor failed", () => {
		const store = new TaskStore();
		store.upsert("chat", [{ taskId: "ghost" }], 1000);
		store.upsert("chat", [{ taskId: "ok", status: "completed" }], 1000);
		store.upsert("chat", [{ taskId: "bad", status: "error" }], 1000);
		store.upsert("chat", [{ taskId: "live", status: "queued" }], 1000);
		const rows = projectAgentHubRows(store.tree("chat"), 2000);
		expect(rows.find((row) => row.taskId === "ghost")!.elapsedMs).toBeUndefined();
		expect(summarizeAgentHubRows(rows)).toEqual({
			total: 4,
			active: 1,
			completed: 1,
			failed: 1,
		});
	});

	test("sanitizes display text without touching ids", () => {
		const store = new TaskStore();
		store.upsert(
			"chat",
			[{ taskId: "t\u001b", description: "do\u001b[31m it\nnow", agent: "a\u0007b" }],
			0,
		);
		const [row] = projectAgentHubRows(store.tree("chat"), 0);
		expect(row!.label).toBe("do it now");
		expect(row!.agent).toBe("a b");
		expect(row!.taskId).toBe("t\u001b");
	});

	test("formats elapsed time", () => {
		expect(formatElapsed(undefined)).toBe("");
		expect(formatElapsed(42_900)).toBe("42s");
		expect(formatElapsed(185_000)).toBe("3m05s");
		expect(formatElapsed(3_720_000)).toBe("1h02m");
	});
});

describe("task feed", () => {
	test("is pinned to one session and only notifies for it", () => {
		const tree = new TaskTreeController({ requestRender: () => {} });
		const feed = tree.feed("chat");
		let notified = 0;
		const off = feed.subscribe(() => notified++);
		tree.store.upsert("other", [{ taskId: "x", status: "running" }], 0);
		expect(notified).toBe(0);
		tree.store.upsert("chat", [{ taskId: "y", status: "running" }], 0);
		expect(notified).toBe(1);
		expect(feed.rows().map((row) => row.task.taskId)).toEqual(["y"]);
		off();
		tree.store.upsert("chat", [{ taskId: "z", status: "running" }], 0);
		expect(notified).toBe(1);
		tree.dispose();
	});
});

function hub(options: { pollMs?: number; history?: () => ChatHistoryMessage[] | Error } = {}) {
	const tree = new TaskTreeController({ requestRender: () => {} });
	const events = { closed: 0, repaints: 0, loads: [] as string[] };
	let now = 10_000;
	const component = new AgentHubComponent({
		feed: tree.feed("chat"),
		loadTranscript: async (row) => {
			events.loads.push(row.sessionId!);
			const result = options.history?.() ?? [];
			if (result instanceof Error) throw result;
			return result;
		},
		rows: () => 30,
		close: () => events.closed++,
		repaint: () => events.repaints++,
		now: () => now,
		pollMs: options.pollMs ?? 5,
		tickMs: 3_600_000,
	});
	return {
		tree,
		component,
		events,
		setNow: (value: number) => {
			now = value;
		},
		text: (width = 100) => component.render(width).join("\n"),
		dispose: () => {
			component.dispose();
			tree.dispose();
		},
	};
}

const settle = () => Bun.sleep(20);

describe("hub component", () => {
	test("lists subagents live and never exceeds the width", () => {
		const h = hub();
		expect(h.text()).toContain("No subagents in this session yet.");
		h.tree.store.upsert(
			"chat",
			[
				{
					taskId: "a",
					sessionId: "sess-a",
					status: "running",
					description: "Write the tests",
					agent: "coder",
					progress: "editing foo.ts",
				},
			],
			9_000,
		);
		const text = h.text();
		expect(text).toContain("1 agent · 1 running");
		expect(text).toContain("running");
		expect(text).toContain("1s");
		expect(text).toContain("@coder");
		expect(text).toContain("Write the tests");
		expect(text).toContain("editing foo.ts");
		h.tree.store.upsert("chat", [{ taskId: "b", status: "error", description: "Broken" }], 9_500);
		expect(h.text()).toContain("2 agents · 1 running · 1 failed");
		expect(h.events.repaints).toBeGreaterThan(0);
		for (const width of [20, 40, 80, 160]) {
			for (const line of h.component.render(width)) {
				expect(visibleWidth(line)).toBeLessThanOrEqual(width);
			}
		}
		h.dispose();
	});

	test("selection follows the task through reordering and arrows move it", () => {
		const h = hub();
		h.tree.store.upsert("chat", [{ taskId: "a" }, { taskId: "b" }, { taskId: "c" }], 0);
		h.component.handleInput(DOWN);
		expect(h.component.selected?.taskId).toBe("b");
		h.tree.store.upsert("chat", [{ taskId: "b", status: "running" }], 1);
		expect(h.component.selected?.taskId).toBe("b");
		h.component.handleInput("G");
		expect(h.component.selected?.taskId).toBe("c");
		h.dispose();
	});

	test("enter opens the child's transcript, esc backs out, esc again closes", async () => {
		const h = hub({
			history: () => [
				message("1", "user", "Please inspect the build"),
				message("2", "tool_use", "{}", { toolCallId: "t1", toolName: "bash", title: "ls" }),
				message("3", "tool_result", "file-a\nfile-b", {
					toolCallId: "t1",
					toolName: "bash",
					title: "ls",
					ok: true,
				}),
				message("4", "assistant", "The build is **green**."),
			],
		});
		h.tree.store.upsert(
			"chat",
			[{ taskId: "a", sessionId: "sess-a", status: "completed", description: "Inspect" }],
			0,
		);
		h.component.handleInput(ENTER);
		expect(h.component.view).toBe("transcript");
		await settle();
		const text = h.text();
		expect(h.events.loads).toEqual(["sess-a"]);
		expect(text).toContain("Inspect");
		expect(text).toContain("Please inspect the build");
		expect(text).toContain("bash — ls");
		expect(text).toContain("file-a");
		expect(text).toContain("The build is green.");
		// The call and its result are one line.
		expect(text.match(/bash — ls/g)).toHaveLength(1);
		h.component.handleInput(ESC);
		expect(h.component.view).toBe("table");
		expect(h.events.closed).toBe(0);
		h.component.handleInput(ESC);
		expect(h.events.closed).toBe(1);
		h.dispose();
	});

	test("polls a running child, then reads once more after it ends and stops", async () => {
		let messages = [message("1", "user", "go")];
		const h = hub({ history: () => messages });
		h.tree.store.upsert("chat", [{ taskId: "a", sessionId: "sess-a", status: "running" }], 0);
		h.component.handleInput(ENTER);
		await Bun.sleep(60);
		const whileRunning = h.events.loads.length;
		expect(whileRunning).toBeGreaterThan(2);
		messages = [message("1", "user", "go"), message("2", "assistant", "all done")];
		h.tree.store.upsert("chat", [{ taskId: "a", status: "completed" }], 100);
		await Bun.sleep(60);
		expect(h.text()).toContain("all done");
		const afterFinish = h.events.loads.length;
		await Bun.sleep(60);
		expect(h.events.loads.length).toBe(afterFinish);
		h.dispose();
	});

	test("polling is bounded: repeated failures stop it, r retries, errors stay visible", async () => {
		let failing = true;
		const h = hub({
			history: () => (failing ? new Error("boom") : [message("1", "assistant", "back")]),
		});
		h.tree.store.upsert("chat", [{ taskId: "a", sessionId: "sess-a", status: "running" }], 0);
		h.component.handleInput(ENTER);
		await Bun.sleep(80);
		expect(h.events.loads).toHaveLength(3);
		expect(h.text()).toContain("Could not read the transcript: boom");
		expect(h.text()).toContain("stalled");
		failing = false;
		h.component.handleInput("r");
		await settle();
		expect(h.text()).toContain("back");
		expect(h.text()).not.toContain("Could not read");
		h.dispose();
	});

	test("a child without a session never calls the loader and says why", async () => {
		const h = hub();
		h.tree.store.upsert("chat", [{ taskId: "a", status: "running", progress: "starting" }], 0);
		h.component.handleInput(ENTER);
		await settle();
		expect(h.events.loads).toEqual([]);
		expect(h.text()).toContain("has not reported a session yet");
		expect(h.text()).toContain("latest: starting");
		// The session id arriving starts the first read.
		h.tree.store.upsert("chat", [{ taskId: "a", sessionId: "sess-a" }], 1);
		await settle();
		expect(h.events.loads[0]).toBe("sess-a");
		h.dispose();
	});

	test("dispose stops reads", async () => {
		const h = hub();
		h.tree.store.upsert("chat", [{ taskId: "a", sessionId: "sess-a", status: "running" }], 0);
		h.component.handleInput(ENTER);
		await settle();
		h.component.dispose();
		const loads = h.events.loads.length;
		await Bun.sleep(40);
		expect(h.events.loads.length).toBe(loads);
		h.tree.dispose();
	});

	test("transcript scrolls and follows the newest line until the reader scrolls up", async () => {
		const many = Array.from({ length: 60 }, (_, index) =>
			message(String(index), "user", `line ${index}`),
		);
		const h = hub({ history: () => many });
		h.tree.store.upsert("chat", [{ taskId: "a", sessionId: "sess-a", status: "completed" }], 0);
		h.component.handleInput(ENTER);
		await settle();
		expect(h.text()).toContain("line 59");
		expect(h.text()).not.toContain("line 0");
		h.component.handleInput("g");
		expect(h.text()).toContain("line 0");
		expect(h.text()).not.toContain("line 59");
		h.component.handleInput("G");
		expect(h.text()).toContain("line 59");
		h.dispose();
	});
});

describe("transcript rows", () => {
	test("strip terminal escapes from untrusted text and stay within the width", () => {
		const rows = transcriptLines(
			[
				message("1", "user", "hi \u001b]0;owned\u0007there \u001b[2J\r\nnext"),
				message("2", "assistant", "plain `code` and a very long line ".repeat(8)),
				message("3", "tool_result", "x".repeat(300), { toolName: "bash\u001b[31m", ok: false }),
			],
			40,
		);
		for (const row of rows) {
			expect(visibleWidth(row)).toBeLessThanOrEqual(40);
			expect(row).not.toContain("\u0007");
			expect(row).not.toContain("]0;owned");
		}
		expect(rows.join("\n")).toContain("there");
	});
});
