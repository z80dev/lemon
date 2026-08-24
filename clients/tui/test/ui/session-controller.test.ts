import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { AppShell } from "../../src/app.ts";
import { FakeControlPlane } from "../../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import type { ChatHistoryMessage } from "../../src/protocol/types.ts";
import { SessionStore } from "../../src/store/session-store.ts";
import {
	pendingApprovalsFrom,
	synthesizeHistory,
} from "../../src/ui/controllers/session-controller.ts";
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

async function bootApp(sessionKey = "tui-a") {
	const server = await FakeControlPlane.start();
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

	// Watch the render gestures: a switch is one of only two paths allowed to
	// clear the terminal's own scrollback.
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
		expect(key.startsWith("tui-")).toBe(true);
		const send = server.requestsFor("chat.send").at(-1);
		expect(send?.params).toMatchObject({ sessionKey: key, prompt: "first thing" });
		// A minted session has no stored history worth a round-trip.
		expect(server.requestsFor("chat.history")).toHaveLength(0);
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

describe("SessionController.resync", () => {
	test("appends only messages newer than what is already on screen", async () => {
		const { app, server } = await bootApp("tui-a");
		await app.submit("hello");
		await waitFor(() => app.store.focused.blocks.length > 0, { what: "the echoed prompt" });
		const lastAt = app.store.focused.lastBlock?.at ?? 0;
		server.respondWith("chat.history", {
			messages: [
				{ id: "old", role: "user", content: "hello", timestampMs: lastAt - 1000 },
				{
					id: "new",
					role: "assistant",
					content: "answered while offline",
					timestampMs: lastAt + 1000,
				},
			],
		});

		await app.sessions.resync();

		const text = chatText(app);
		expect(text).toContain("answered while offline");
		// "hello" is the prompt already echoed; recovering it again would read as
		// the user having sent it twice.
		expect(text.match(/hello/g) ?? []).toHaveLength(1);
	});

	test("measures against the last daemon message, not the reconnect notice", async () => {
		const { app, server } = await bootApp("tui-a");
		await app.submit("hello");
		await waitFor(() => app.store.focused.blocks.length > 0, { what: "the echoed prompt" });
		const promptAt = app.store.focused.lastBlock?.at ?? 0;
		// What a reconnect writes: notices stamped *after* everything the daemon
		// answered while the socket was down.
		app.events.notice("reconnected", "warning");
		server.respondWith("chat.history", {
			messages: [
				{ id: "old", role: "user", content: "hello", timestampMs: promptAt - 5000 },
				{
					id: "missed",
					role: "assistant",
					content: "answered mid-outage",
					timestampMs: promptAt + 1,
				},
			],
		});

		await app.sessions.resync();

		expect(chatText(app)).toContain("answered mid-outage");
	});

	test("hydrates a transcript that holds nothing but connection notices", async () => {
		const { app, server } = await bootApp("tui-a");
		// The banner's "connected to lemon" notice is the only block on screen.
		expect(app.store.focused.blocks.every((block) => block.kind === "notice")).toBe(true);
		server.respondWith("chat.history", {
			messages: [
				{ id: "m1", role: "assistant", content: "from before this client", timestampMs: 5 },
			],
		});

		await app.sessions.resync();

		expect(chatText(app)).toContain("from before this client");
	});

	test("marks sessions the daemon no longer lists as no longer busy", async () => {
		const { app, server } = await bootApp("tui-a");
		const other = app.store.session("tui-b");
		other.busy = true;
		other.activeRunId = "run-b";
		server.respondWith("sessions.active.list", { sessions: [{ sessionKey: "tui-a" }] });

		await app.sessions.resync();

		expect(other.busy).toBe(false);
		expect(other.activeRunId).toBeUndefined();
		expect(app.store.session("tui-a").busy).toBe(true);
	});

	test("re-adds approvals the client missed while disconnected", async () => {
		const { app, server } = await bootApp("tui-a");
		server.respondWith("exec.approvals.get", {
			approvals: [{ approvalId: "ap-1", tool: "bash", sessionKey: "tui-a" }],
		});

		await app.sessions.resync();

		expect(app.store.approvals.has("ap-1")).toBe(true);
	});
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

	test("maps tool records to completed tool blocks, named from whatever field exists", () => {
		const session = build([
			{ id: "m3", role: "tool", content: "exit 0", timestampMs: 6, name: "bash" },
		]);
		expect(session.blocks[0]).toMatchObject({
			kind: "tool",
			phase: "completed",
			title: "bash",
			ok: true,
		});
	});

	test("keeps anything else as a notice rather than dropping it", () => {
		const session = build([{ id: "m4", role: "system", content: "reindexed", timestampMs: 7 }]);
		expect(session.blocks[0]).toMatchObject({ kind: "notice" });
		expect((session.blocks[0] as { text: string }).text).toContain("reindexed");
	});
});

describe("pendingApprovalsFrom", () => {
	test("reads both payload shapes and skips entries with no id", () => {
		const fromWrapped = pendingApprovalsFrom({
			approvals: [{ approvalId: "a" }, { tool: "bash" }],
		});
		expect(fromWrapped.map((entry) => entry.approvalId)).toEqual(["a"]);

		// The snake-cased spelling is normalized onto `approvalId` so the store
		// keys pending approvals the same way live events do.
		const fromBareList = pendingApprovalsFrom([{ approval_id: "b" }]);
		expect(fromBareList.map((entry) => entry.approvalId)).toEqual(["b"]);

		expect(pendingApprovalsFrom(undefined)).toEqual([]);
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
