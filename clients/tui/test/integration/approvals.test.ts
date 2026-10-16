/**
 * The approval round trip: a tool asks, the panel appears and takes the
 * keyboard, a key answers it, and the transcript keeps the record.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { AppShell } from "../../src/app.ts";
import { FakeControlPlane } from "../../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import type { ApprovalBlock } from "../../src/store/transcript-model.ts";
import { resetBlockIds } from "../../src/store/transcript-model.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal, renderPlain } from "../helpers/memory-terminal.ts";
import { unfinalizedBlocks } from "../helpers/transcript.ts";
import { waitFor } from "../helpers/wait.ts";

const SESSION = "tui-approvals";

const teardown: Array<() => void> = [];

beforeEach(() => {
	resetBlockIds();
	initTheme({ colorLevel: 3 });
});

afterEach(() => {
	while (teardown.length > 0) teardown.pop()?.();
	resetTheme();
	invalidateThemeAdapters();
});

async function boot(
	options: { methods?: string[]; script?: (server: FakeControlPlane) => void } = {},
) {
	const server = await FakeControlPlane.start({ methods: options.methods });
	teardown.push(() => server.stop());
	server.onMethod("chat.send", (params: { sessionKey: string }) => ({
		runId: "run-1",
		sessionKey: params.sessionKey,
	}));
	server.respondWith("exec.approval.resolve", { resolved: true });
	options.script?.(server);

	const terminal = new MemoryTerminal();
	const client = new ControlPlaneClient({
		url: server.url,
		socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
	});
	const app = new AppShell({
		url: server.url,
		sessionKey: SESSION,
		version: "test",
		client,
		terminal,
		smoothStreaming: false,
	});
	teardown.push(() => app.stop());
	await app.start();
	return { app, server, terminal };
}

function requested(server: FakeControlPlane, overrides: Record<string, unknown> = {}) {
	server.pushEvent("exec.approval.requested", {
		approvalId: "ap-1",
		runId: "run-1",
		sessionKey: SESSION,
		agentId: null,
		tool: "bash",
		action: { command: "echo p4check" },
		rationale: "the model wants a shell",
		requestedAtMs: Date.now(),
		expiresAtMs: Date.now() + 60_000,
		...overrides,
	});
}

function panelText(app: AppShell): string {
	return renderPlain(app.approvalContainer.render(80));
}

function transcript(app: AppShell): string {
	return renderPlain(app.chatContainer.render(80));
}

function approvalBlock(app: AppShell, sessionKey = SESSION): ApprovalBlock | undefined {
	return app.store
		.session(sessionKey)
		.blocks.find((block): block is ApprovalBlock => block.kind === "approval");
}

async function waitForPanel(app: AppShell) {
	await waitFor(() => app.approvals.panel.visible, { what: "the approval panel" });
}

describe("approval flow", () => {
	test("a request mounts the panel, takes focus, and shows the command", async () => {
		const { app, server } = await boot();
		requested(server);
		await waitForPanel(app);

		const text = panelText(app);
		expect(text).toContain("approval required · bash");
		expect(text).toContain("echo p4check");
		expect(text).toContain("1  allow once");
		// The panel, not the editor, owns the keyboard while a tool is blocked.
		expect(app.tui.getFocused()).toBe(app.approvals.panel);
		expect(app.statusData().approvals).toBe(1);
		expect(transcript(app)).toContain("approval requested for bash");
	});

	test("a number key resolves it and the record is annotated", async () => {
		const { app, server, terminal } = await boot();
		requested(server);
		await waitForPanel(app);

		terminal.sendInput("1");
		await server.waitForRequest("exec.approval.resolve");
		expect(server.requestsFor("exec.approval.resolve")[0]!.params).toEqual({
			approvalId: "ap-1",
			decision: "approve_once",
		});

		await waitFor(() => app.store.pendingApprovals === 0, { what: "the approval to clear" });
		expect(app.approvals.panel.visible).toBe(false);
		expect(app.approvalContainer.render(80)).toEqual([]);
		// Focus goes back where the user's next keystroke belongs.
		expect(app.tui.getFocused()).toBe(app.editor);

		expect(approvalBlock(app)).toMatchObject({ status: "resolved", decision: "approve_once" });
		await waitFor(() => transcript(app).includes("approval granted for bash (once)"), {
			what: "the annotated record",
		});
	});

	test("escape denies", async () => {
		const { app, server, terminal } = await boot();
		requested(server);
		await waitForPanel(app);

		terminal.sendInput("\x1b");
		const frame = await server.waitForRequest("exec.approval.resolve");
		expect((frame.params as { decision: string }).decision).toBe("deny");
		await waitFor(() => transcript(app).includes("approval denied for bash"), {
			what: "the denied record",
		});
	});

	test("a resolve the daemon refuses puts the panel back", async () => {
		const { app, server, terminal } = await boot();
		server.failWith("exec.approval.resolve", "GONE", "that approval expired");
		requested(server);
		await waitForPanel(app);

		terminal.sendInput("1");
		await waitFor(() => transcript(app).includes("approval failed"), {
			what: "the failure notice",
		});
		// Still pending, still on screen: a tool is still blocked on an answer.
		expect(app.store.pendingApprovals).toBe(1);
		expect(app.approvals.panel.visible).toBe(true);
		expect(approvalBlock(app)?.status).toBe("pending");
	});

	test("a resolve refused as expired forgets the request instead of restoring the panel", async () => {
		const { app, server, terminal } = await boot();
		server.failWith("exec.approval.resolve", "CONFLICT", "Approval expired", {
			approvalId: "ap-1",
			reason: "expired",
		});
		requested(server);
		await waitForPanel(app);

		terminal.sendInput("1");
		await waitFor(() => transcript(app).includes("approval for bash expired — the run ended"), {
			what: "the expired notice",
		});
		expect(app.store.pendingApprovals).toBe(0);
		expect(app.approvals.panel.visible).toBe(false);
		expect(approvalBlock(app)).toMatchObject({ status: "resolved", decision: "expired" });
		expect(transcript(app)).not.toContain("approval failed");
	});

	test("the daemon expiring an approval dismisses the panel and never reads as granted", async () => {
		const { app, server } = await boot();
		requested(server);
		await waitForPanel(app);

		server.pushEvent("exec.approval.resolved", {
			approvalId: "ap-1",
			decision: "expired",
			runId: "run-1",
			sessionKey: SESSION,
			agentId: null,
			tool: "bash",
		});

		await waitFor(() => app.approvals.panel.visible === false, { what: "the panel to dismiss" });
		expect(app.store.pendingApprovals).toBe(0);
		expect(server.requestsFor("exec.approval.resolve")).toHaveLength(0);
		expect(approvalBlock(app)).toMatchObject({ status: "resolved", decision: "expired" });
		await waitFor(() => transcript(app).includes("approval expired for bash — the run ended"), {
			what: "the expired record",
		});
		expect(transcript(app)).not.toContain("approval granted");
	});

	test("someone else answering dismisses the panel and annotates the record", async () => {
		const { app, server } = await boot();
		requested(server);
		await waitForPanel(app);

		server.pushEvent("exec.approval.resolved", {
			approvalId: "ap-1",
			decision: "approve_global",
			runId: "run-1",
			sessionKey: SESSION,
			agentId: null,
			tool: "bash",
		});

		await waitFor(() => app.approvals.panel.visible === false, { what: "the panel to dismiss" });
		expect(app.store.pendingApprovals).toBe(0);
		expect(server.requestsFor("exec.approval.resolve")).toHaveLength(0);
		await waitFor(() => transcript(app).includes("approval granted for bash (global)"), {
			what: "the annotated record",
		});
	});

	test("two requests are answered one at a time", async () => {
		const { app, server, terminal } = await boot();
		requested(server);
		requested(server, { approvalId: "ap-2", tool: "write", action: { path: "/tmp/x" } });
		await waitForPanel(app);
		await waitFor(() => app.store.pendingApprovals === 2, { what: "both requests" });

		expect(panelText(app)).toContain("echo p4check");
		terminal.sendInput("1");
		await waitFor(() => panelText(app).includes("/tmp/x"), { what: "the second request" });
		expect(app.approvals.panel.event?.approvalId).toBe("ap-2");
	});

	test("a background session's request badges the status bar but does not steal focus", async () => {
		const { app, server } = await boot();
		requested(server, { approvalId: "ap-bg", sessionKey: "someone-else" });
		await waitFor(() => app.store.pendingApprovals === 1, { what: "the background request" });

		expect(app.approvals.panel.visible).toBe(false);
		expect(app.tui.getFocused()).toBe(app.editor);
		expect(app.statusData().approvals).toBe(1);

		// …and is still answerable without switching to that session.
		await app.submit("/approve 1 session");
		const frame = await server.waitForRequest("exec.approval.resolve");
		expect(frame.params).toEqual({ approvalId: "ap-bg", decision: "approve_session" });
		await waitFor(() => app.store.pendingApprovals === 0, { what: "the approval to clear" });
		expect(approvalBlock(app, "someone-else")).toMatchObject({
			status: "resolved",
			decision: "approve_session",
		});
	});

	test("/deny answers through the same path", async () => {
		const { app, server } = await boot();
		requested(server);
		await waitForPanel(app);

		await app.submit("/deny 1");
		const frame = await server.waitForRequest("exec.approval.resolve");
		expect(frame.params).toEqual({ approvalId: "ap-1", decision: "deny" });
		await waitFor(() => app.approvals.panel.visible === false, { what: "the panel to dismiss" });
	});

	test("a pending request stays mutable until its decision is resolved", async () => {
		const { app, server, terminal } = await boot();
		requested(server);
		await waitForPanel(app);

		app.chatContainer.render(80);
		expect(unfinalizedBlocks(app.chatContainer).length).toBeGreaterThan(0);

		terminal.sendInput("1");
		await waitFor(() => app.store.pendingApprovals === 0, { what: "the approval to clear" });
		app.chatContainer.render(80);
		expect(unfinalizedBlocks(app.chatContainer)).toHaveLength(0);
	});

	test("resolving something that is already gone says so instead of throwing", async () => {
		const { app } = await boot();
		await app.approvals.resolve("ap-missing", "approve_once");
		expect(transcript(app)).toContain("no longer pending");
	});
});

describe("approval panel and the rest of the keyboard", () => {
	test("global keys are inert while a decision is pending", async () => {
		const { app, server, terminal } = await boot();
		await app.submit("hello");
		requested(server);
		await waitForPanel(app);

		const before = app.store.focused.blocks.length;
		// Ctrl+L would otherwise clear the transcript out from under the question.
		terminal.sendInput("\x0c");
		expect(app.store.focused.blocks.length).toBe(before);
	});
});

describe("plan proposals", () => {
	const PLAN = Array.from({ length: 30 }, (_, i) => `${i + 1}. step ${i + 1}`).join("\n");

	/** A daemon in plan mode whose approved proposal switches it to code mode. */
	async function bootPlanning(options: { flipOnApprove?: boolean } = {}) {
		const state = { mode: "plan" as "plan" | "code" };
		const booted = await boot({
			methods: [...new FakeControlPlane().advertisedMethods, "sessions.plan"],
			script: (server) => {
				server.onMethod("sessions.plan", (params: { sessionKey: string }) => ({
					sessionKey: params.sessionKey,
					plan: { mode: state.mode, path: "/plans/fix-api-plan.md", content: PLAN },
				}));
				server.onMethod("exec.approval.resolve", (params: { decision: string }) => {
					if (params.decision === "approve_once" && options.flipOnApprove !== false) {
						state.mode = "code";
					}
					return { resolved: true };
				});
			},
		});
		// The handshake's own read, not one the test asked for.
		await waitFor(() => booted.app.statusData().planMode === "plan", { what: "plan mode" });
		return { ...booted, state };
	}

	function propose(server: FakeControlPlane) {
		requested(server, {
			approvalId: "ap-plan",
			tool: "propose_plan",
			action: { title: "Fix the API", path: "/plans/fix-api-plan.md", plan: PLAN },
			rationale: 'Approve plan "Fix the API" and start implementation?',
		});
	}

	function statusLine(app: AppShell): string {
		return renderPlain(app.statusLineContainer.render(120));
	}

	test("connecting reads plan mode and the status line shows it", async () => {
		const { app } = await bootPlanning();
		await waitFor(() => app.statusData().planMode === "plan", { what: "plan mode" });
		expect(statusLine(app)).toMatch(/^plan · /);
	});

	test("the panel offers only execute or refine, with a bounded plan preview", async () => {
		const { app, server } = await bootPlanning();
		propose(server);
		await waitForPanel(app);
		const text = panelText(app);
		expect(text).toContain("Plan proposal · Fix the API");
		expect(text).toContain("plan file: /plans/fix-api-plan.md");
		expect(text).toContain("1. step 1");
		expect(text).not.toContain("30. step 30");
		expect(text).toContain("… 18 more lines (30 total)");
		expect(text).toContain("1  Approve and execute");
		expect(text).toContain("2  Refine plan");
		expect(text).not.toContain("allow for this session");
		expect(text).not.toContain("allow always");
	});

	test("approving executes: plan mode goes off and the indicator disappears", async () => {
		const { app, server, terminal } = await bootPlanning();
		propose(server);
		await waitForPanel(app);
		terminal.sendInput("1");
		const frame = await server.waitForRequest("exec.approval.resolve");
		expect(frame.params).toEqual({ approvalId: "ap-plan", decision: "approve_once" });
		await waitFor(() => app.statusData().planMode === "code", { what: "plan mode off" });
		expect(statusLine(app)).not.toMatch(/^plan · /);
		await waitFor(() => transcript(app).includes("plan approved — executing"), {
			what: "the record",
		});
	});

	test("a status read that races the daemon's switch cannot bring plan mode back", async () => {
		const { app, server, terminal } = await bootPlanning({ flipOnApprove: false });
		propose(server);
		await waitForPanel(app);
		const reads = server.requestsFor("sessions.plan").length;
		terminal.sendInput("1");
		await waitFor(() => server.requestsFor("sessions.plan").length > reads, {
			what: "the post-approval refresh",
		});
		// Responses arrive in request order, so once this read settles the
		// listener's earlier one has been applied (or dropped) too.
		await app.refreshPlanMode(SESSION, { afterApproval: true });
		expect(app.statusData().planMode).toBe("code");
	});

	test("refining keeps plan mode on and the record says so", async () => {
		const { app, server, terminal, state } = await bootPlanning();
		propose(server);
		await waitForPanel(app);
		terminal.sendInput("2");
		const frame = await server.waitForRequest("exec.approval.resolve");
		expect(frame.params).toEqual({ approvalId: "ap-plan", decision: "deny" });
		await waitFor(() => transcript(app).includes("plan sent back for refinement"), {
			what: "the record",
		});
		expect(state.mode).toBe("plan");
		expect(app.statusData().planMode).toBe("plan");
		expect(statusLine(app)).toMatch(/^plan · /);
	});

	test("/approve refuses a scoped approval of a plan proposal", async () => {
		const { app, server } = await bootPlanning();
		propose(server);
		await waitForPanel(app);
		await app.submit("/approve 1 session");
		expect(server.requestsFor("exec.approval.resolve")).toEqual([]);
		expect(transcript(app)).toContain("scopes do not apply");
	});

	test("focusing another session reads that session's plan mode", async () => {
		const { app, server, state } = await bootPlanning();
		state.mode = "code";
		app.store.setFocused("tui-other");
		await waitFor(() => app.store.session("tui-other").planMode === "code", {
			what: "the other session's mode",
		});
		expect(app.statusData().planMode).toBe("code");
		expect(statusLine(app)).not.toMatch(/^plan · /);
		expect(
			server.requestsFor("sessions.plan").map((frame) => frame.params as { sessionKey: string }),
		).toContainEqual(expect.objectContaining({ sessionKey: "tui-other", action: "status" }));
	});

	test("a completed run on the focused session re-reads plan mode", async () => {
		const { app, server, state } = await bootPlanning();
		await waitFor(() => app.statusData().planMode === "plan", { what: "plan mode" });
		state.mode = "code";
		server.pushEvent("agent", {
			type: "completed",
			runId: "run-9",
			sessionKey: SESSION,
			ok: true,
			answer: "done",
		});
		await waitFor(() => app.statusData().planMode === "code", { what: "the resync" });
	});
});
