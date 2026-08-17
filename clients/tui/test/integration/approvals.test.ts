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

async function boot() {
	const server = await FakeControlPlane.start();
	teardown.push(() => server.stop());
	server.onMethod("chat.send", (params: { sessionKey: string }) => ({
		runId: "run-1",
		sessionKey: params.sessionKey,
	}));
	server.respondWith("exec.approval.resolve", { resolved: true });

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

	test("a pending request keeps the transcript's live region open, a resolved one lets it close", async () => {
		const { app, server, terminal } = await boot();
		requested(server);
		await waitForPanel(app);

		app.chatContainer.render(80);
		expect(app.chatContainer.getNativeScrollbackLiveRegionStart()).toBeGreaterThan(0);

		terminal.sendInput("1");
		await waitFor(() => app.store.pendingApprovals === 0, { what: "the approval to clear" });
		app.chatContainer.render(80);
		expect(app.chatContainer.getNativeScrollbackLiveRegionStart()).toBeUndefined();
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
