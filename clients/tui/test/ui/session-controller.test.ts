import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { AppShell } from "../../src/app.ts";
import { DEFAULT_METHODS, FakeControlPlane } from "../../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import type {
	ApprovalRequestedEvent,
	ChatHistoryMessage,
	ExecPendingApproval,
	SessionsSnapshotResult,
} from "../../src/protocol/types.ts";
import { SessionStore } from "../../src/store/session-store.ts";
import { ToolCardComponent } from "../../src/ui/components/tool-card.ts";
import { synthesizeHistory } from "../../src/ui/controllers/session-controller.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal, renderPlain } from "../helpers/memory-terminal.ts";
import { waitFor } from "../helpers/wait.ts";

const teardown: Array<() => void> = [];

beforeEach(() => {
	initTheme({ colorLevel: 3 });
});

afterEach(() => {
	while (teardown.length > 0) teardown.pop()?.();
	resetTheme();
	invalidateThemeAdapters();
});

interface RenderCall {
	force: boolean;
	clearScrollback: boolean;
}

async function bootApp(sessionKey = "tui-a", snapshot = false) {
	const server = await FakeControlPlane.start({
		methods: snapshot ? [...DEFAULT_METHODS, "sessions.snapshot"] : DEFAULT_METHODS,
	});
	teardown.push(() => server.stop());
	server.onMethod("chat.send", (params: { sessionKey: string }) => ({
		runId: `run-${params.sessionKey}`,
		sessionKey: params.sessionKey,
	}));
	server.respondWith("chat.history", { messages: [] });
	server.respondWith("sessions.delete", { deleted: true });
	server.respondWith("sessions.list", { sessions: [] });
	server.respondWith("sessions.active.list", { sessions: [] });
	server.respondWith("exec.approvals.get", { approvals: [] });
	if (snapshot)
		server.onMethod("sessions.snapshot", ({ sessionKey }: { sessionKey: string }) =>
			recoverySnapshot(sessionKey),
		);

	const terminal = new MemoryTerminal();
	const client = new ControlPlaneClient({
		url: server.url,
		socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
	});
	const app = new AppShell({
		url: server.url,
		sessionKey,
		version: "test",
		client,
		terminal,
		smoothStreaming: false,
	});
	teardown.push(() => app.stop());
	await app.start();
	if (snapshot) await app.sessions.initialize();

	// Track scrollback replacement separately from ordinary repaint requests.
	const renders: RenderCall[] = [];
	const original = app.tui.requestRender.bind(app.tui);
	app.tui.requestRender = (force = false, options?: { clearScrollback?: boolean }) => {
		renders.push({ force, clearScrollback: options?.clearScrollback === true });
		original(force, options);
	};

	return { app, server, terminal, renders };
}

function chatText(app: AppShell): string {
	return renderPlain(app.chatContainer.render(80));
}

describe("SessionController.switch", () => {
	test("parks the outgoing draft and restores the incoming one", async () => {
		const { app } = await bootApp("tui-a");

		app.editor.setText("half-written prompt for a");
		await app.sessions.switch("tui-b");
		expect(app.sessionKey).toBe("tui-b");
		expect(app.editor.getExpandedText()).toBe("");

		app.editor.setText("something else for b");
		await app.sessions.switch("tui-a");
		expect(app.editor.getExpandedText()).toBe("half-written prompt for a");

		await app.sessions.switch("tui-b");
		expect(app.editor.getExpandedText()).toBe("something else for b");
	});

	test("hydrates a cold session from chat.history and finalizes what it built", async () => {
		const { app, server } = await bootApp("tui-a");
		server.onMethod("chat.history", (params: { sessionKey: string }) =>
			params.sessionKey === "tui-b"
				? {
						messages: [
							{ id: "m1", role: "user", content: "what is the plan?", timestampMs: 1000 },
							{ id: "m2", role: "assistant", content: "ship the switcher", timestampMs: 2000 },
						],
					}
				: { messages: [] },
		);

		await app.sessions.switch("tui-b");

		const request = server.requestsFor("chat.history").at(-1);
		expect(request?.params).toMatchObject({
			sessionKey: "tui-b",
			limit: 100,
			includeFullText: true,
		});
		const text = chatText(app);
		expect(text).toContain("what is the plan?");
		expect(text).toContain("ship the switcher");
		// A rebuilt session must not report a live region: an assistant block left
		// in the streaming state pins the scrollback commit seam open forever.
		const statuses = app.store
			.session("tui-b")
			.blocks.filter((block) => block.kind === "assistant")
			.map((block) => (block as { status: string }).status);
		expect(statuses).toEqual(["done"]);
	});

	test("clears scrollback exactly once per switch", async () => {
		const { app, renders } = await bootApp("tui-a");
		renders.length = 0;

		await app.sessions.switch("tui-b");

		expect(renders.filter((call) => call.clearScrollback)).toHaveLength(1);
	});

	test("hydrates only once, and never over a transcript built from events", async () => {
		const { app, server } = await bootApp("tui-a");
		server.pushEvent("agent", { type: "started", runId: "run-b", sessionKey: "tui-b" });
		server.pushEvent("chat", {
			type: "delta",
			runId: "run-b",
			sessionKey: "tui-b",
			seq: 1,
			text: "live text",
		});
		await waitFor(() => app.store.session("tui-b").blocks.length > 0, {
			what: "the background session to accumulate a block",
		});
		const before = server.requestsFor("chat.history").length;

		await app.sessions.switch("tui-b");
		await app.sessions.switch("tui-a");
		await app.sessions.switch("tui-b");

		expect(server.requestsFor("chat.history")).toHaveLength(before);
		expect(chatText(app)).toContain("live text");
	});

	test("resets the incoming session's unread count", async () => {
		const { app, server } = await bootApp("tui-a");
		server.pushEvent("agent", {
			type: "completed",
			runId: "run-b",
			sessionKey: "tui-b",
			ok: true,
			answer: "done in the background",
		});
		await waitFor(() => app.store.session("tui-b").unread > 0, { what: "an unread block" });

		await app.sessions.switch("tui-b");
		expect(app.store.session("tui-b").unread).toBe(0);
		expect(app.store.totalUnread()).toBe(0);
	});

	test("switching to the session already focused is a no-op", async () => {
		const { app, renders } = await bootApp("tui-a");
		app.editor.setText("keep me");
		renders.length = 0;

		await app.sessions.switch("tui-a");

		expect(app.editor.getExpandedText()).toBe("keep me");
		expect(renders.filter((call) => call.clearScrollback)).toHaveLength(0);
	});
});

describe("SessionController.create", () => {
	test("mints a key, focuses it, and sends the first prompt there", async () => {
		const { app, server } = await bootApp("tui-a");

		const key = await app.sessions.create(undefined, "first thing");

		expect(app.sessionKey).toBe(key);
		expect(key).toMatch(/^agent:default:tui:local:dm:([0-9a-f]{16}-)?[0-9a-f-]{36}$/);
		const send = server.requestsFor("chat.send").at(-1);
		expect(send?.params).toMatchObject({ sessionKey: key, prompt: "first thing" });
		// A minted session has no stored history worth a round-trip.
		expect(server.requestsFor("chat.history")).not.toContainEqual(
			expect.objectContaining({ params: expect.objectContaining({ sessionKey: key }) }),
		);
	});

	test("accepts an explicit key and creates nothing daemon-side without a prompt", async () => {
		const { app, server } = await bootApp("tui-a");

		await app.sessions.create("review-branch");

		expect(app.sessionKey).toBe("review-branch");
		expect(server.requestsFor("chat.send")).toHaveLength(0);
	});

	test("does not collide with a key already in use", async () => {
		const { app } = await bootApp("tui-a");

		// Minted keys are second-resolution, so two in a row are the test: the
		// second must not land on the first's transcript.
		const first = await app.sessions.create();
		const second = await app.sessions.create();

		expect(second).not.toBe(first);
		expect(app.store.sessions.has(first)).toBe(true);
		expect(app.store.sessions.has(second)).toBe(true);
	});
});

describe("SessionController.close", () => {
	test("asks first, and deletes only after the confirmation", async () => {
		const { app, server } = await bootApp("tui-a");
		await app.sessions.create("scratch");

		app.sessions.requestClose("scratch");
		expect(app.selectors.isOpen).toBe(true);
		expect(server.requestsFor("sessions.delete")).toHaveLength(0);

		// Enter on the default row is the affirmative option.
		app.selectors.current?.handleInput?.("\r");
		await waitFor(() => server.requestsFor("sessions.delete").length > 0, {
			what: "the delete request",
		});
		expect(server.requestsFor("sessions.delete")[0]?.params).toEqual({ sessionKey: "scratch" });
		expect(app.store.sessions.has("scratch")).toBe(false);
	});

	test("moves focus off a session before forgetting it", async () => {
		const { app } = await bootApp("tui-a");
		await app.sessions.create("scratch");
		expect(app.sessionKey).toBe("scratch");

		await app.sessions.close("scratch", { confirmed: true });

		expect(app.sessionKey).toBe("tui-a");
		expect(app.store.sessions.has("scratch")).toBe(false);
	});

	test("forgets the closed session's draft", async () => {
		const { app } = await bootApp("tui-a");
		await app.sessions.create("scratch");
		app.editor.setText("draft in scratch");
		await app.sessions.switch("tui-a");
		expect(app.store.drafts.get("scratch")).toBe("draft in scratch");

		await app.sessions.close("scratch", { confirmed: true });
		expect(app.store.drafts.has("scratch")).toBe(false);
	});
});

describe("SessionController.forgetDeleted", () => {
	test("moves focus, clears the deleted draft, and does not issue a duplicate delete", async () => {
		const { app, server } = await bootApp("tui-a");
		await app.sessions.create("scratch");
		app.editor.setText("draft that belongs to deleted scratch");

		await app.sessions.forgetDeleted("scratch");

		expect(app.sessionKey).toBe("tui-a");
		expect(app.store.sessions.has("scratch")).toBe(false);
		expect(app.store.drafts.has("scratch")).toBe(false);
		expect(server.requestsFor("sessions.delete")).toHaveLength(0);
	});
});

function recoverySnapshot(
	key = "tui-a",
	runId: string | null = null,
): Extract<SessionsSnapshotResult, { status: "ok" }> {
	return {
		status: "ok",
		sessionKey: key,
		identity: {
			sessionKey: key,
			sessionId: "native-1",
			branchId: "branch-a",
			revision: "rev-a",
			runId,
			attempt: runId,
		},
		consistency: { boundary: "stable_owner_reads", atomic: false, eventCursor: null },
		snapshot: {
			phase: runId ? "running" : "idle",
			terminal: !runId,
			answer: { text: "", canonical: !runId, truncated: false },
			messages: [],
			actions: [],
			approvals: { status: "ok", items: [] },
			children: { status: "ok", items: [] },
			processes: { status: "ok", items: [] },
			todos: { status: "ok", items: [] },
			plan: { status: "ok", value: { mode: "code", content: null } },
		},
	};
}

function pendingApproval(id: string, sessionKey = "tui-a"): ExecPendingApproval {
	return {
		id,
		runId: "run-a",
		sessionKey,
		agentId: null,
		tool: "bash",
		action: { title: id, kind: "local_smoke" },
		rationale: null,
		requestedAtMs: 1,
		expiresAtMs: null,
	};
}

function requestedApproval(id: string, sessionKey = "tui-a"): ApprovalRequestedEvent {
	const { id: approvalId, ...fields } = pendingApproval(id, sessionKey);
	return { ...fields, approvalId };
}

function deferred<T>() {
	let resolve!: (value: T) => void;
	const promise = new Promise<T>((done) => {
		resolve = done;
	});
	return { promise, resolve };
}

describe("SessionController owner recovery", () => {
	test("unknown phase with a fixed identity preserves prior activity and discloses bounded omissions", async () => {
		for (const previouslyBusy of [false, true]) {
			const { app, server } = await bootApp("tui-a", true);
			if (previouslyBusy) app.events.noteRunStarted("previous-run");
			const result = recoverySnapshot("tui-a", "fixed-but-unconfirmed-run");
			result.snapshot.phase = "unknown";
			result.snapshot.answer = {
				text: "retained partial answer",
				canonical: false,
				truncated: true,
			};
			result.snapshot.messagesTruncated = true;
			result.snapshot.actionsTruncated = true;
			result.snapshot.actions = [
				{
					id: "unconfirmed-call",
					role: "tool_use",
					content: "",
					timestampMs: 1,
					toolCallId: "unconfirmed-call",
					toolName: "bash",
					phase: "started",
				},
			];
			server.respondWith("sessions.snapshot", result);
			await app.sessions.resync();
			expect(app.store.focused.busy).toBe(previouslyBusy);
			expect(app.store.focused.activeRunId).toBe(previouslyBusy ? "previous-run" : undefined);
			expect(app.store.focused.byActionId.get("unconfirmed-call")?.historical).toBe(true);
			expect(app.store.focused.assistantFor("fixed-but-unconfirmed-run")?.status).not.toBe(
				"streaming",
			);
			const text = chatText(app);
			expect(text).toContain("run state unknown");
			expect(text).toContain("messages snapshot truncated");
			expect(text).toContain("actions snapshot truncated");
			expect(text).toContain("answer snapshot truncated");
		}
	});

	test("recovers missed tool completion and canonical answer once; terminal cannot revive", async () => {
		const { app, server } = await bootApp("tui-a", true);
		app.events.noteRunStarted("run-a");
		app.store.focused.upsertTool(
			{ id: "call-a", kind: "tool", title: "bash", detail: {} },
			"started",
			{ runId: "run-a" },
		);
		const result = recoverySnapshot("tui-a", "run-a");
		result.snapshot.terminal = true;
		result.snapshot.phase = "completed";
		result.snapshot.answer = {
			text: "complete canonical answer",
			canonical: true,
			truncated: false,
		};
		result.snapshot.actions = [
			{
				id: "result-a",
				role: "tool_result",
				content: "exit 0",
				timestampMs: 2,
				toolCallId: "call-a",
				toolName: "bash",
				phase: "completed",
				ok: true,
			},
		];
		const offline = app.client.events.waitFor("state");
		const reconnected = app.client.events.waitFor("resync-needed");
		server.dropConnections();
		expect((await offline).state).not.toBe("online");
		server.respondWith("sessions.snapshot", result);
		await reconnected;
		await app.sessions.resync();
		await app.sessions.resync();
		expect(app.store.focused.byActionId.get("call-a")).toMatchObject({
			phase: "completed",
			ok: true,
		});
		expect(app.store.focused.assistantFor("run-a")).toMatchObject({
			status: "done",
			text: "complete canonical answer",
		});
		expect(
			app.store.focused.blocks.filter(
				(block) => block.kind === "tool" && block.actionId === "call-a",
			),
		).toHaveLength(1);
		const received = app.client.events.waitFor("agent");
		server.pushEvent("agent", { type: "started", runId: "run-a", sessionKey: "tui-a" });
		await received;
		await app.sessions.resync();
		expect(app.store.focused.busy).toBe(false);
	});

	test("replaces pending approvals without reviving disconnected decisions", async () => {
		const { app, server } = await bootApp("tui-a", true);
		const old = {
			approvalId: "old",
			runId: "run-a",
			sessionKey: "tui-a",
			agentId: null,
			tool: "bash",
			action: {},
			rationale: null,
			requestedAtMs: null,
			expiresAtMs: null,
		};
		app.store.addApproval(old);
		const result = recoverySnapshot("tui-a", "run-a");
		result.snapshot.approvals.items = [pendingApproval("current")];
		server.respondWith("sessions.snapshot", result);
		await app.sessions.resync();
		expect([...app.store.approvals.keys()]).toEqual(["current"]);
		const received = app.client.events.waitFor("exec.approval.requested");
		server.pushEvent("exec.approval.requested", old);
		await received;
		await app.sessions.resync();
		expect([...app.store.approvals.keys()]).toEqual(["current"]);
	});

	test("producer id rows recover two usable approvals and one decision leaves the other pending", async () => {
		const { app, server } = await bootApp("tui-a", true);
		const first = pendingApproval("approval-a");
		const second = pendingApproval("approval-b");
		const result = recoverySnapshot("tui-a", "run-a");
		result.snapshot.approvals.items = [first, second];
		server.respondWith("sessions.snapshot", result);
		server.respondWith("exec.approval.resolve", { resolved: true });
		await app.sessions.resync();

		expect([...app.store.approvals.keys()]).toEqual(["approval-a", "approval-b"]);
		expect(app.approvals.pendingForFocused().map(({ event }) => event.approvalId)).toEqual([
			"approval-a",
			"approval-b",
		]);
		expect(app.approvals.panel.visible).toBe(true);
		expect(renderPlain(app.approvalContainer.render(80))).toContain("approval-a");
		expect(server.requestsFor("exec.approval.resolve")).toHaveLength(0);

		await app.approvals.resolve("approval-a", "approve_once");
		expect(server.requestsFor("exec.approval.resolve").at(-1)?.params).toEqual({
			approvalId: "approval-a",
			decision: "approve_once",
		});
		expect([...app.store.approvals.keys()]).toEqual(["approval-b"]);
		expect(renderPlain(app.approvalContainer.render(80))).toContain("approval-b");
		result.snapshot.approvals.items = [second];
		await app.sessions.resync();
		expect([...app.store.approvals.keys()]).toEqual(["approval-b"]);
		expect(server.requestsFor("exec.approval.resolve")).toHaveLength(1);
	});

	test("replacement and authoritative empty revoke only the selected session's real IDs", async () => {
		const { app, server } = await bootApp("tui-a", true);
		app.store.addApproval(requestedApproval("old"));
		app.store.addApproval(requestedApproval("kept"));
		app.store.addApproval(requestedApproval("foreign", "tui-b"));
		const result = recoverySnapshot("tui-a", "run-a");
		result.snapshot.approvals.items = [pendingApproval("kept"), pendingApproval("new")];
		server.respondWith("sessions.snapshot", result);
		await app.sessions.resync();
		expect([...app.store.approvals.keys()]).toEqual(["kept", "foreign", "new"]);
		result.snapshot.approvals.items = [];
		await app.sessions.resync();
		expect([...app.store.approvals.keys()]).toEqual(["foreign"]);
		expect(server.requestsFor("exec.approval.resolve")).toHaveLength(0);
	});

	test("malformed or unsupported identity sets never revoke existing pending IDs or add partial rows", async () => {
		const { app, server } = await bootApp("tui-a", true);
		app.store.addApproval(requestedApproval("real"));
		app.store.addApproval(requestedApproval("foreign", "tui-b"));
		const invalidSets: unknown[] = [
			[requestedApproval("unsupported-event-shape")],
			[{ ...pendingApproval("missing"), id: undefined }],
			[{ ...pendingApproval("empty"), id: "" }],
			[{ ...pendingApproval("whitespace"), id: "  " }],
			[{ ...pendingApproval("numeric"), id: 42 }],
			[null],
			[pendingApproval("same"), pendingApproval("same")],
			[pendingApproval("wrong-session", "tui-b")],
			[pendingApproval("foreign")],
			undefined,
		];
		for (const invalid of invalidSets) {
			const result = recoverySnapshot("tui-a", "run-a");
			// Deliberately malformed wire responses, not supported protocol variants.
			result.snapshot.approvals.items = invalid as ExecPendingApproval[];
			server.respondWith("sessions.snapshot", result);
			await app.sessions.resync();
			expect([...app.store.approvals.keys()]).toEqual(["real", "foreign"]);
			expect(chatText(app)).toContain("approvals state unavailable: invalid snapshot identity");
			expect(server.requestsFor("exec.approval.resolve")).toHaveLength(0);
		}
		const mixed = recoverySnapshot("tui-a", "run-a");
		mixed.snapshot.approvals.items = [
			pendingApproval("valid-but-incomplete"),
			{ ...pendingApproval("bad"), id: "" },
		];
		server.respondWith("sessions.snapshot", mixed);
		await app.sessions.resync();
		expect([...app.store.approvals.keys()]).toEqual(["real", "foreign"]);
	});

	test("unavailable and bounded partial approval reads preserve pending IDs while scope revocation clears only its session", async () => {
		const { app, server } = await bootApp("tui-a", true);
		app.store.addApproval(requestedApproval("real"));
		app.store.addApproval(requestedApproval("foreign", "tui-b"));
		const result = recoverySnapshot("tui-a", "run-a");
		result.snapshot.approvals = { status: "unavailable", items: [] };
		server.respondWith("sessions.snapshot", result);
		await app.sessions.resync();
		expect([...app.store.approvals.keys()]).toEqual(["real", "foreign"]);
		result.snapshot.approvals = {
			status: "ok",
			items: [pendingApproval("recovered")],
			truncated: true,
		};
		await app.sessions.resync();
		expect([...app.store.approvals.keys()]).toEqual(["real", "foreign", "recovered"]);
		expect(chatText(app)).toContain("approvals snapshot truncated");
		result.snapshot.approvals = { status: "forbidden", items: [] };
		await app.sessions.resync();
		expect([...app.store.approvals.keys()]).toEqual(["foreign"]);
		app.store.addApproval(requestedApproval("real"));
		server.failWith("sessions.snapshot", "FORBIDDEN", "scope revoked");
		await app.sessions.resync();
		expect([...app.store.approvals.keys()]).toEqual(["foreign"]);
		expect(server.requestsFor("exec.approval.resolve")).toHaveLength(0);
	});

	test("a foreign session resolution cannot clear a recovered real ID", async () => {
		const { app, server } = await bootApp("tui-a", true);
		const result = recoverySnapshot("tui-a", "run-a");
		result.snapshot.approvals.items = [pendingApproval("real"), pendingApproval("other")];
		server.respondWith("sessions.snapshot", result);
		await app.sessions.resync();
		const foreign = app.client.events.waitFor("exec.approval.resolved");
		server.pushEvent("exec.approval.resolved", {
			approvalId: "real",
			decision: "deny",
			sessionKey: "tui-b",
			runId: "run-a",
		});
		await foreign;
		expect([...app.store.approvals.keys()]).toEqual(["real", "other"]);
		const own = app.client.events.waitFor("exec.approval.resolved");
		server.pushEvent("exec.approval.resolved", {
			approvalId: "real",
			decision: "deny",
			sessionKey: "tui-a",
			runId: "run-a",
		});
		await own;
		expect([...app.store.approvals.keys()]).toEqual(["other"]);
	});

	test("restores child/process identities and replaces rewind todo and plan", async () => {
		const { app, server } = await bootApp("tui-a", true);
		app.store.focused.setPlan("plan", "/old/private/plan.md");
		const result = recoverySnapshot("tui-a", "run-new");
		result.identity.branchId = "rewound";
		result.identity.revision = "rev-new";
		result.snapshot.children.items = [
			{
				taskId: "fixed-child",
				runId: "child-run",
				parentRunId: "run-new",
				status: "completed",
				terminal: true,
			},
		];
		result.snapshot.processes.items = [
			{
				identity: "fixed-process",
				classification: "outcome_unknown",
				status: "lost",
				reason: "owner_lost",
			},
			{ identity: "active-process", classification: "accepted", status: "running", reason: null },
			{ identity: "done-process", classification: "accepted", status: "completed", reason: null },
		];
		result.snapshot.todos.items = [
			{ id: "new-todo", content: "new branch task", status: "pending" },
		];
		server.respondWith("sessions.snapshot", result);
		await app.sessions.resync();
		expect(app.store.focused.planMode).toBe("code");
		expect(app.store.focused.planPath).toBeUndefined();
		expect(app.store.focused.ownedProcessStates).toEqual(result.snapshot.processes.items);
		expect(app.store.focused.byActionId.get("snapshot:todos")?.detail).toMatchObject({
			details: { todos: result.snapshot.todos.items },
		});
		expect(app.store.focused.byActionId.get("snapshot:process:fixed-process")).toMatchObject({
			historical: true,
		});
		expect(app.store.focused.byActionId.get("snapshot:process:active-process")).toMatchObject({
			phase: "started",
			historical: false,
		});
		expect(app.store.focused.byActionId.get("snapshot:process:done-process")).toMatchObject({
			phase: "completed",
			ok: true,
		});
	});

	test("a replacement session instance clears unavailable cached owner projections", async () => {
		const { app, server } = await bootApp("tui-a", true);
		app.store.focused.setPlan("plan", "/old/private/plan.md");
		app.store.focused.ownedProcessStates = [{ identity: "obsolete-process", status: "running" }];
		const result = recoverySnapshot();
		result.identity.sessionId = "replacement-native-session";
		result.snapshot.plan = { status: "unavailable", value: null };
		result.snapshot.processes = { status: "unavailable", items: [] };
		server.respondWith("sessions.snapshot", result);
		await app.sessions.resync();
		expect(app.store.focused.snapshotIdentity?.sessionId).toBe("replacement-native-session");
		expect(app.store.focused.planMode).toBeUndefined();
		expect(app.store.focused.planPath).toBeUndefined();
		expect(app.store.focused.ownedProcessStates).toEqual([]);
	});

	for (const trigger of ["chat", "stream.resync"] as const) {
		test(`${trigger} racing the RPC retries without appending no-cursor snapshot text`, async () => {
			const { app, server } = await bootApp("tui-a", true);
			app.store.focused.appendDelta("run-a", 1, "obsolete live text");
			app.store.focused.upsertTool(
				{ id: "obsolete-call", kind: "tool", title: "bash", detail: {} },
				"started",
				{ runId: "run-a" },
			);
			app.store.addApproval({
				approvalId: "obsolete-approval",
				runId: "run-a",
				sessionKey: "tui-a",
				agentId: null,
				tool: "bash",
				action: {},
				rationale: null,
				requestedAtMs: null,
				expiresAtMs: null,
			});
			const entered = deferred<void>();
			const release = deferred<Extract<SessionsSnapshotResult, { status: "ok" }>>();
			let reads = 0;
			server.onMethod("sessions.snapshot", () => {
				reads++;
				if (reads === 1) {
					entered.resolve();
					return release.promise;
				}
				const current = recoverySnapshot("tui-a", "current-run");
				current.identity.branchId = "selected-branch";
				current.identity.revision = "selected-revision";
				current.snapshot.answer.text = "whole latest text";
				return current;
			});
			const recovering = app.sessions.resync();
			await entered.promise;
			const received = app.client.events.waitFor(trigger);
			if (trigger === "chat") {
				server.pushEvent("chat", {
					type: "delta",
					runId: "run-a",
					sessionKey: "tui-a",
					seq: 99,
					text: "must not append",
				});
			} else {
				server.pushEvent("stream.resync", { reason: "overflow", sessionKey: "tui-a" });
			}
			await received;
			release.resolve(recoverySnapshot("tui-a", "run-a"));
			await recovering;
			expect(reads).toBe(2);
			expect(app.store.focused.bufferFor("current-run")).toBe("whole latest text");
			expect(app.store.focused.assistantFor("run-a")).toBeUndefined();
			expect(app.store.focused.byActionId.has("obsolete-call")).toBe(false);
			expect(app.store.approvals.has("obsolete-approval")).toBe(false);
			expect(
				app.store.focused.blocks.some(
					(block) => block.kind === "assistant" && block.text.includes("obsolete live text"),
				),
			).toBe(false);
		});
	}

	test("late selected-session promises do not restore abandoned state or draft", async () => {
		const { app, server } = await bootApp("tui-a", true);
		const entered = deferred<void>();
		const release = deferred<Extract<SessionsSnapshotResult, { status: "ok" }>>();
		server.onMethod("sessions.snapshot", ({ sessionKey }: { sessionKey: string }) => {
			if (sessionKey === "tui-b") {
				entered.resolve();
				return release.promise;
			}
			return recoverySnapshot(sessionKey);
		});
		app.editor.setText("keep a draft");
		const oldSwitch = app.sessions.switch("tui-b");
		await entered.promise;
		await app.sessions.switch("tui-a");
		const old = recoverySnapshot("tui-b", "old-run");
		old.snapshot.answer.text = "abandoned text";
		release.resolve(old);
		await oldSwitch;
		expect(app.sessionKey).toBe("tui-a");
		expect(app.editor.getExpandedText()).toBe("keep a draft");
		expect(app.store.session("tui-b").assistantFor("old-run")).toBeUndefined();
	});

	test("authority races retry boundedly and owner/auth failures never imply idle", async () => {
		const { app, server } = await bootApp("tui-a", true);
		app.events.noteRunStarted("run-a");
		const before = server.requestsFor("sessions.snapshot").length;
		server.respondWith("sessions.snapshot", {
			status: "retry",
			sessionKey: "tui-a",
			identity: recoverySnapshot().identity,
			reason: "snapshot_raced",
			retrySafe: true,
		});
		await app.sessions.resync();
		expect(server.requestsFor("sessions.snapshot").length - before).toBe(3);
		expect(app.store.focused.busy).toBe(true);
		server.failWith("sessions.snapshot", "FORBIDDEN", "scope revoked");
		await app.sessions.resync();
		expect(app.store.focused.busy).toBe(true);
		expect(app.store.focused.activeRunId).toBe("run-a");
		expect(app.client.queued).toHaveLength(0);
	});

	test("overflow and reconnect use the same authority with no mutation replay", async () => {
		const { app, server } = await bootApp("tui-a", true);
		const result = recoverySnapshot("tui-a", "run-a");
		result.snapshot.terminal = true;
		result.snapshot.phase = "completed";
		result.snapshot.answer.text = "finished during outage";
		server.respondWith("sessions.snapshot", result);
		const resync = app.client.events.waitFor("resync-needed");
		server.pushEvent("stream.resync", { reason: "overflow" });
		await resync;
		await app.sessions.resync();
		expect(app.store.focused.assistantFor("run-a")?.text).toBe("finished during outage");
		const reconnected = app.client.events.waitFor("resync-needed");
		server.dropConnections();
		await reconnected;
		await app.sessions.resync();
		expect(app.store.focused.busy).toBe(false);
		expect(server.requestsFor("chat.send")).toHaveLength(0);
	});

	test("foreign snapshot and obsolete attempt events cannot mutate the selected run", async () => {
		const { app, server } = await bootApp("tui-a", true);
		const current = recoverySnapshot("tui-a", "current-run");
		current.snapshot.answer.text = "current answer";
		server.respondWith("sessions.snapshot", current);
		await app.sessions.resync();
		server.respondWith("sessions.snapshot", recoverySnapshot("foreign", "foreign-run"));
		await app.sessions.resync();
		expect(app.store.focused.assistantFor("foreign-run")).toBeUndefined();
		const received = app.client.events.waitFor("agent");
		server.pushEvent("agent", {
			type: "tool_use",
			sessionKey: "tui-a",
			runId: "current-run",
			phase: "started",
			identity: { ...current.identity, branchId: "abandoned", attempt: "obsolete" },
			action: { id: "stale-action", kind: "tool", title: "bash", detail: {} },
		});
		await received;
		await app.sessions.resync();
		expect(app.store.focused.byActionId.has("stale-action")).toBe(false);
		expect(app.store.focused.bufferFor("current-run")).toBe("current answer");
	});

	test("a late nonterminal snapshot cannot reopen a finished attempt", async () => {
		const { app, server } = await bootApp("tui-a", true);
		const result = recoverySnapshot("tui-a", "run-a");
		result.snapshot.terminal = true;
		result.snapshot.phase = "completed";
		result.snapshot.answer.text = "finished";
		server.respondWith("sessions.snapshot", result);
		await app.sessions.resync();
		server.respondWith("sessions.snapshot", recoverySnapshot("tui-a", "run-a"));
		await app.sessions.resync();
		expect(app.store.focused.busy).toBe(false);
		expect(app.store.focused.assistantFor("run-a")?.status).toBe("done");
	});

	for (const boundary of ["sessionId", "branchId", "attempt"] as const) {
		test(`terminal state from another ${boundary} cannot fence the selected attempt`, async () => {
			const { app, server } = await bootApp("tui-a", true);
			const previous = recoverySnapshot("tui-a", "run-a");
			previous.snapshot.phase = "completed";
			previous.snapshot.terminal = true;
			previous.snapshot.answer.text = "obsolete terminal answer";
			server.respondWith("sessions.snapshot", previous);
			await app.sessions.resync();
			const current = recoverySnapshot("tui-a", "run-a");
			current.identity[boundary] = `current-${boundary}`;
			current.snapshot.answer.text = "current active answer";
			server.respondWith("sessions.snapshot", current);
			await app.sessions.resync();
			expect(app.store.focused.snapshotIdentity?.[boundary]).toBe(`current-${boundary}`);
			expect(app.store.focused.busy).toBe(true);
			expect(app.store.focused.bufferFor("run-a")).toBe("current active answer");
		});
	}
});

describe("synthesizeHistory", () => {
	const build = (messages: ChatHistoryMessage[]) => {
		const session = new SessionStore("tui-x");
		synthesizeHistory(session, messages);
		return session;
	};

	test("maps user messages to user blocks with their stored timestamp", () => {
		const session = build([{ id: "m1", role: "user", content: "hi", timestampMs: 4242 }]);
		expect(session.blocks).toHaveLength(1);
		expect(session.blocks[0]).toMatchObject({ kind: "user", text: "hi", at: 4242 });
	});

	test("maps assistant messages to finalized blocks under a synthetic run", () => {
		const session = build([{ id: "m2", role: "assistant", content: "answer", timestampMs: 5 }]);
		const block = session.blocks[0] as {
			kind: string;
			status: string;
			runId: string;
			text: string;
		};
		expect(block.kind).toBe("assistant");
		expect(block.status).toBe("done");
		expect(block.runId).toBe("history:m2");
		expect(block.text).toBe("answer");
	});

	test("a live delta for the synthetic run still lands (the seq was never taken)", () => {
		const session = build([{ id: "m2", role: "assistant", content: "answer", timestampMs: 5 }]);
		const result = session.appendDelta("history:m2", 1, " more");
		expect(result.accepted).toBe(true);
	});

	test("maps explicit tool results to completed tool blocks with their recorded outcome", () => {
		const session = build([
			{
				id: "m3",
				role: "tool_result",
				content: "exit 0",
				timestampMs: 6,
				toolCallId: "call-3",
				toolName: "bash",
				phase: "completed",
				ok: true,
				cancelled: false,
			},
		]);
		expect(session.blocks[0]).toMatchObject({
			kind: "tool",
			phase: "completed",
			title: "bash",
			ok: true,
		});
	});

	test("a historical receipt without authoritative timing omits duration after remount", () => {
		const session = build([
			{ id: "old-tool", role: "tool", name: "read", content: "saved output", timestampMs: 6 },
		]);
		const block = session.blocks[0];
		if (block?.kind !== "tool") throw new Error("expected historical tool");
		expect(block.completedAt).toBeUndefined();
		let original: string | undefined;
		for (const clock of [600_000, 1_200_000]) {
			const component = new ToolCardComponent(block, { now: () => clock });
			component.update(block);
			const text = renderPlain(component.render(100));
			expect(text).toContain("saved output");
			expect(text.split("\n")[0]).not.toMatch(/\d+(ms|s)\s*$/);
			expect(component.describe().p).not.toHaveProperty("took");
			expect(component.describe().p).not.toHaveProperty("age");
			if (original !== undefined) expect(text).toBe(original);
			original = text;
			component.dispose();
		}
	});

	test("keeps anything else as a notice rather than dropping it", () => {
		const session = build([{ id: "m4", role: "system", content: "reindexed", timestampMs: 7 }]);
		expect(session.blocks[0]).toMatchObject({ kind: "notice" });
		expect((session.blocks[0] as { text: string }).text).toContain("reindexed");
	});
});

describe("SessionController routing hydration", () => {
	test("a switch learns the target session's resolved model", async () => {
		const { app, server } = await bootApp("tui-a");
		server.respondWith("session.detail", {
			sessionKey: "tui-b",
			session: {
				sessionKey: "tui-b",
				model: "claude-sonnet-4",
				provider: "anthropic",
				contextWindow: 200_000,
				thinkingLevel: "high",
				modelSource: "session",
			},
		});

		await app.sessions.switch("tui-b");
		await waitFor(() => app.store.session("tui-b").model !== undefined, {
			what: "the resolved model",
		});

		const session = app.store.session("tui-b");
		expect(session.model).toBe("claude-sonnet-4");
		expect(session.provider).toBe("anthropic");
		expect(session.contextWindow).toBe(200_000);
		expect(session.thinkingLevel).toBe("high");
		expect(session.modelSource).toBe("detail");
	});

	test("hydration does not undo a model the session already ran on", async () => {
		const { app, server } = await bootApp("tui-a");
		server.respondWith("session.detail", {
			session: { sessionKey: "tui-b", model: "claude-sonnet-4" },
		});
		// A run already told us what this session is actually on.
		app.store.session("tui-b").setModel({ model: "gpt-4o" }, "run");

		await app.sessions.switch("tui-b");
		await app.sessions.hydrateRouting(app.store.session("tui-b"));

		expect(app.store.session("tui-b").model).toBe("gpt-4o");
	});

	test("a daemon that errors on session.detail leaves the status bar alone", async () => {
		const { app } = await bootApp("tui-a");
		// No `session.detail` responder is registered, so the call rejects.
		await app.sessions.hydrateRouting(app.store.focused);
		expect(app.store.focused.model).toBeUndefined();
	});
});

test("rewind reload replaces abandoned history with full active-branch messages and retains the draft", async () => {
	const { app, server } = await bootApp("tui-a");
	app.store.focused.appendDelta("history:a", Number.NaN, "abandoned answer");
	app.store.focused.finalizeRun("history:a", { ok: true });
	app.editor.setText("recalled prompt");
	server.respondWith("chat.history", {
		messages: [{ id: "a", role: "assistant", content: "active answer", timestampMs: 10 }],
	});
	await app.sessions.reload("tui-a");
	expect(chatText(app)).toContain("active answer");
	expect(chatText(app)).not.toContain("abandoned answer");
	expect(app.editor.getExpandedText()).toBe("recalled prompt");
	expect(server.requestsFor("chat.history").at(-1)?.params).toMatchObject({
		sessionKey: "tui-a",
		cwd: process.cwd(),
		includeFullText: true,
	});
});
