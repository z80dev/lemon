import { afterEach, beforeEach, expect, test } from "bun:test";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import type { AgentToolUseEvent } from "../../src/protocol/types.ts";
import { TASK_TREE_WINDOW } from "../../src/ui/components/task-tree.ts";
import { TaskTreeController } from "../../src/ui/controllers/task-tree-controller.ts";
import { TASK_PROGRESS_LIMIT, taskUpdatesFromEvent } from "../../src/ui/task-progress.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";

const controllers: TaskTreeController[] = [];
beforeEach(() => initTheme({ colorLevel: 0 }));
afterEach(() => {
	for (const controller of controllers.splice(0)) controller.dispose();
	resetTheme();
});

function progress(
	taskId: string,
	status: string,
	details: Record<string, unknown> = {},
	sessionKey = "chat",
): AgentToolUseEvent {
	return {
		type: "tool_use",
		runId: "parent-run",
		sessionKey,
		phase: "updated",
		action: {
			id: "launch",
			kind: "subagent",
			title: "Launch children",
			detail: {
				name: "task",
				partial_result: {
					content: [{ type: "text", text: `${taskId} output` }],
					details: { task_id: taskId, status, description: `Work ${taskId}`, ...details },
				},
			},
		},
	};
}

function controller() {
	let now = 1000;
	let renders = 0;
	let blurred = 0;
	const tree = new TaskTreeController({
		now: () => now,
		requestRender: () => {
			renders += 1;
		},
		onBlur: () => {
			blurred += 1;
		},
	});
	controllers.push(tree);
	tree.setSession("chat");
	return {
		tree,
		setNow: (value: number) => {
			now = value;
		},
		renders: () => renders,
		blurred: () => blurred,
	};
}

test("panel shows three children, latest interleaved progress, persona and observed elapsed", () => {
	const { tree, setNow } = controller();
	expect(tree.panel.render(120)).toEqual([]);
	for (const id of ["one", "two", "three"]) {
		tree.ingest(
			progress(id, "running", {
				agent: "researcher",
				current_action: { title: `reading ${id}`, kind: "tool", phase: "updated" },
			}),
		);
	}
	tree.toggle();
	setNow(4000);
	tree.ingest(progress("two", "running", { current_action: { title: "editing two" } }));
	const text = tree.panel.render(160).join("\n");
	expect(text).toContain("3 children · 3 active");
	expect(text).toContain("running 3s · Work one @researcher · one");
	expect(text).toContain("reading one");
	expect(text).toContain("editing two");
	expect(text).not.toContain("reading two");
	expect(text).toContain("reading three");
	expect(tree.store.items("chat")).toHaveLength(3);
	expect(tree.ticking).toBe(true);
});

test("launch and parent completion do not finish children; late results stop the ticker", () => {
	const { tree, setNow } = controller();
	tree.toggle();
	tree.ingest(progress("one", "running"));
	const receipt = progress("unused", "running");
	receipt.phase = "completed";
	receipt.action.detail = {
		name: "task",
		details: { tasks: [{ task_id: "one", status: "queued" }] },
	};
	tree.ingest(receipt);
	tree.ingest({
		type: "completed",
		runId: "parent-run",
		sessionKey: "chat",
		ok: true,
		answer: "Children launched",
		durationMs: 20,
	});
	expect(tree.store.find("chat", "one")?.finishedAt).toBeUndefined();
	expect(tree.store.find("chat", "one")?.status).toBe("running");
	expect(tree.store.find("chat", "one")?.progress).toBe("one output");
	expect(tree.ticking).toBe(true);
	setNow(6000);
	tree.ingest(progress("one", "completed", { output: "Finished after launch ended" }));
	expect(tree.ticking).toBe(false);
	setNow(20000);
	const text = tree.panel.render(140).join("\n");
	expect(text).toContain("completed 5s");
	expect(text).toContain("Finished after launch ended");
	expect(tree.store.items("chat")).toHaveLength(1);
});

test("cancel requests stay live until real aborted, cancelled or error child results", () => {
	const { tree } = controller();
	tree.toggle();
	for (const id of ["one", "two", "three"]) tree.ingest(progress(id, "running"));
	tree.ingest(progress("one", "cancelling"));
	expect(tree.store.find("chat", "one")?.finishedAt).toBeUndefined();
	expect(tree.ticking).toBe(true);
	tree.ingest(progress("one", "aborted"));
	tree.ingest(progress("two", "cancelled"));
	tree.ingest(progress("three", "error", { error: "Child process failed" }));
	expect(tree.store.items("chat").map((task) => task.status)).toEqual([
		"aborted",
		"aborted",
		"error",
	]);
	expect(tree.ticking).toBe(false);
	expect(tree.panel.render(120).join("\n")).toContain("Child process failed");
	tree.ingest(progress("three", "running"));
	expect(tree.ticking).toBe(false);
	expect(tree.store.find("chat", "three")?.progress).toBe("Child process failed");
});

test("join receipts update the same rows and preserve independent terminal states", () => {
	const { tree } = controller();
	for (const id of ["one", "two", "three"]) tree.ingest(progress(id, "running"));
	const joined = progress("one", "running");
	joined.phase = "completed";
	joined.action.id = "join";
	joined.action.detail = {
		name: "task",
		details: {
			status: "completed",
			tasks: [
				{ task_id: "one", status: "completed", output: "one final" },
				{ task_id: "two", status: "cancelled" },
				{ task_id: "three", status: "error", error: "three failed" },
			],
		},
	};
	tree.ingest(joined);
	expect(tree.store.items("chat")).toHaveLength(3);
	expect(tree.store.find("chat", "one")?.launchActionId).toBe("launch");
	expect(tree.store.find("chat", "one")?.progress).toBe("one final");
	expect(tree.store.items("chat").map((task) => task.status)).toEqual([
		"completed",
		"aborted",
		"error",
	]);
});

test("session switching keeps background and late results with the original owner", () => {
	const { tree } = controller();
	tree.toggle();
	tree.ingest(progress("same", "running", { description: "First chat" }));
	tree.setSession("other");
	expect(tree.panel.render(120).join("\n")).toContain("No child task updates");
	expect(tree.ticking).toBe(false);
	tree.ingest(progress("same", "running", { description: "Other chat" }, "other"));
	tree.ingest(
		progress("same", "completed", { description: "First chat", output: "late first result" }),
	);
	const text = tree.panel.render(120).join("\n");
	expect(text).toContain("Other chat");
	expect(text).not.toContain("First chat");
	expect(text).not.toContain("late first result");
	expect(tree.ticking).toBe(true);
	tree.setSession("chat");
	expect(tree.ticking).toBe(false);
	expect(tree.panel.render(120).join("\n")).toContain("late first result");
	const unowned = progress("must-not-leak", "running");
	unowned.sessionKey = null;
	expect(tree.ingest(unowned)).toBe(false);
	expect(tree.store.items("chat")).toHaveLength(1);
});

test("emitted nested relationships render as a tree without parsing dotted IDs", () => {
	const { tree } = controller();
	tree.toggle();
	tree.ingest(
		progress("opaque.a.b", "running", {
			run_id: "child-run",
			parent_run_id: "root-run",
			parent_session_id: "native-root",
		}),
	);
	tree.ingest(
		progress("root", "running", {
			run_id: "root-run",
			session_id: "native-root",
			description: "Root work",
		}),
	);
	const text = tree.panel.render(160).join("\n");
	expect(text.indexOf("Root work")).toBeLessThan(text.indexOf("opaque.a.b"));
	expect(text).toContain("└─ running 0s · Work opaque.a.b");
});

test("progress is bounded and terminal controls cannot enter the panel", () => {
	const { tree } = controller();
	tree.toggle();
	tree.ingest(
		progress("child", "running", {
			description: "description\u001b[2J\u0007",
			current_action: { title: `${"x".repeat(2000)}\nlatest progress\u001b[31m\u0007` },
		}),
	);
	const child = tree.store.find("chat", "child")!;
	expect(child.progress?.length).toBeLessThanOrEqual(TASK_PROGRESS_LIMIT);
	expect(child.progress).toEndWith("latest progress");
	const text = tree.panel.render(200).join("\n");
	expect(text).not.toContain("\u001b");
	expect(text).not.toContain("\u0007");
	for (const width of [1, 8, 20, 40, 80]) {
		for (const row of tree.panel.render(width))
			expect(visibleWidth(row)).toBeLessThanOrEqual(width);
	}
	expect(tree.panel.render(0)).toEqual([]);
});

test("windowed navigation retains selected identity across nested reparenting", () => {
	const { tree, blurred } = controller();
	tree.toggle();
	tree.panel.focused = true;
	for (let index = 0; index < TASK_TREE_WINDOW + 2; index++)
		tree.ingest(progress(`child-${index}`, "running"));
	for (let index = 0; index < TASK_TREE_WINDOW + 1; index++) tree.panel.handleInput("\u001b[B");
	expect(tree.panel.selected?.task.taskId).toBe(`child-${TASK_TREE_WINDOW + 1}`);
	expect(tree.panel.render(140).join("\n")).toContain(`child-${TASK_TREE_WINDOW + 1}`);
	expect(tree.panel.render(140).join("\n")).toContain("…2 more");
	tree.ingest(progress(`child-${TASK_TREE_WINDOW + 1}`, "running", { parent_run_id: "parent" }));
	tree.ingest(progress("child-0", "running", { run_id: "parent" }));
	expect(tree.panel.selected?.task.taskId).toBe(`child-${TASK_TREE_WINDOW + 1}`);
	tree.panel.handleInput("\u001b");
	expect(blurred()).toBe(1);
	expect(tree.panel.visible).toBe(false);
	expect(tree.ticking).toBe(false);
});

test("visibility and disposal own ticker lifetime without dropping child records", () => {
	const { tree } = controller();
	tree.ingest(progress("one", "running"));
	expect(tree.ticking).toBe(false);
	tree.toggle();
	expect(tree.ticking).toBe(true);
	tree.toggle();
	expect(tree.ticking).toBe(false);
	tree.toggle();
	expect(tree.ticking).toBe(true);
	tree.dispose();
	expect(tree.ticking).toBe(false);
	expect(tree.panel.render(120)).toEqual([]);
	expect(tree.ingest(progress("one", "completed"))).toBe(false);
	expect(tree.store.items("chat")).toHaveLength(1);
});

test("extractor uses child status, not a successful launch receipt or malformed metadata", () => {
	const event = progress("unused", "running");
	event.phase = "completed";
	event.ok = true;
	event.action.detail = {
		name: "task",
		details: { task_id: "known-id", description: "Observed only" },
	};
	expect(taskUpdatesFromEvent(event)[0]?.status).toBeUndefined();
	event.action.detail = {
		name: "task",
		details: { tasks: [null, "bad", { status: "completed" }] },
	};
	expect(taskUpdatesFromEvent(event)).toEqual([]);
	event.action.detail = {
		name: "bash",
		partial_result: { details: { task_id: "not-a-child", status: "running" } },
	};
	expect(taskUpdatesFromEvent(event)).toEqual([]);
});

test("completed receipt overrides a retained partial update and supports agent results", () => {
	const event = progress("one", "running");
	event.phase = "completed";
	event.action.detail = {
		...event.action.detail,
		name: "agent",
		details: { task_id: "one", status: "completed", output: "final result", agent: "reviewer" },
	};
	const { tree } = controller();
	tree.ingest(event);
	expect(tree.store.find("chat", "one")?.status).toBe("completed");
	expect(tree.store.find("chat", "one")?.progress).toBe("final result");
	expect(tree.store.find("chat", "one")?.agent).toBe("reviewer");
});

test("snapshot replacement converges child terminal and unknown identities without a ticker", () => {
	const { tree } = controller();
	tree.toggle();
	tree.ingest(progress("fixed", "running", { run_id: "child-run" }));
	tree.reconcile("chat", {
		status: "ok",
		items: [
			{
				taskId: "fixed",
				runId: "child-run",
				parentRunId: "parent-run",
				status: "completed",
				terminal: true,
			},
			{
				taskId: "lost",
				runId: null,
				sessionId: "child-session",
				status: "unknown",
				terminal: false,
				answer: `\u001b[31m${"x".repeat(1024)}\u001b[0m`,
			},
		],
	});
	expect(tree.store.items("chat").map((task) => [task.taskId, task.status])).toEqual([
		["fixed", "completed"],
		["lost", "unknown"],
	]);
	expect(tree.ticking).toBe(false);
	expect(tree.panel.render(120).join("\n")).toContain("0 active");
	expect(tree.store.find("chat", "lost")?.sessionId).toBe("child-session");
	expect(tree.store.find("chat", "lost")?.progress?.length).toBe(TASK_PROGRESS_LIMIT);
	expect(tree.store.find("chat", "lost")?.progress).not.toContain("\u001b");
	tree.reconcile("chat", { status: "unavailable", items: [] });
	expect(tree.store.items("chat")).toHaveLength(2);
	tree.reconcile("chat", { status: "ok", items: [] });
	expect(tree.store.items("chat")).toHaveLength(0);
});
