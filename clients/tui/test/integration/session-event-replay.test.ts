import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { AppShell } from "../../src/app.ts";
import { DEFAULT_METHODS, FakeControlPlane } from "../../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import { METHOD } from "../../src/protocol/methods.ts";
import type {
	SessionEventBatch,
	SessionEventCursor,
	SessionsEventsResult,
	SessionsSnapshotResult,
} from "../../src/protocol/types.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal } from "../helpers/memory-terminal.ts";
import { waitFor } from "../helpers/wait.ts";

const KEY = "tui-replay";
const teardown: Array<() => void> = [];
beforeEach(() => initTheme({ colorLevel: 3 }));
afterEach(() => {
	while (teardown.length) teardown.pop()?.();
	resetTheme();
	invalidateThemeAdapters();
});

function cursor(seq: number, streamId = "owner-1"): SessionEventCursor {
	return { version: 1, sessionId: "native-1", streamId, seq };
}

function snapshot(
	seq = 0,
	text = "A",
	streamId = "owner-1",
): Extract<SessionsSnapshotResult, { status: "ok" }> {
	return {
		status: "ok",
		sessionKey: KEY,
		identity: {
			sessionKey: KEY,
			sessionId: "native-1",
			branchId: "branch-1",
			revision: "rev-1",
			runId: "run-1",
			attempt: "run-1",
		},
		eventCursor: cursor(seq, streamId),
		consistency: { boundary: "stable_owner_reads", atomic: false, eventCursor: null },
		snapshot: {
			phase: "running",
			terminal: false,
			answer: { text, canonical: false, truncated: false },
			messages: [],
			actions: [],
			approvals: { status: "ok", items: [] },
			children: { status: "ok", items: [] },
			processes: { status: "ok", items: [] },
			todos: { status: "ok", items: [] },
			plan: { status: "ok", value: { mode: "code" } },
		},
	};
}

function delta(seq: number, text: string): SessionEventBatch {
	return {
		cursor: cursor(seq),
		events: [
			{
				event: "chat",
				payload: { type: "delta", runId: "run-1", sessionKey: KEY, seq: 1, text },
			},
		],
	};
}

function page(events: SessionEventBatch[], last: number, hasMore = false): SessionsEventsResult {
	return { status: "ok", sessionKey: KEY, events, cursor: cursor(last), hasMore };
}

function deferred<T>() {
	return Promise.withResolvers<T>();
}

async function boot() {
	const server = await FakeControlPlane.start({
		methods: [...DEFAULT_METHODS, METHOD.sessionsSnapshot, METHOD.sessionsEvents],
		events: ["session.event", "agent", "chat"],
	});
	teardown.push(() => server.stop());
	server.respondWith(METHOD.sessionsSnapshot, snapshot());
	server.respondWith(METHOD.chatHistory, { messages: [] });
	server.respondWith(METHOD.approvalsGet, { approvals: [] });
	server.onMethod(METHOD.sessionsEvents, ({ cursor: after }: { cursor: SessionEventCursor }) =>
		page([], after.seq),
	);
	const client = new ControlPlaneClient({
		url: server.url,
		socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
	});
	const app = new AppShell({
		url: server.url,
		client,
		terminal: new MemoryTerminal(),
		sessionKey: KEY,
		version: "test",
		smoothStreaming: false,
	});
	teardown.push(() => app.stop());
	await app.start();
	await waitFor(() => app.store.focused.eventCursor?.seq === 0);
	return { app, server };
}

async function push(app: AppShell, server: FakeControlPlane, batch: SessionEventBatch) {
	const received = app.client.events.waitFor("session.event");
	server.pushEvent("session.event", { sessionKey: KEY, ...batch });
	await received;
}

describe("session cursor replay through the real client and controllers", () => {
	test("reconnect deduplicates paginated replay, empty batches and racing live events", async () => {
		const { app, server } = await boot();
		app.editor.setText("keep my draft");
		const snapshots = server.requestsFor(METHOD.sessionsSnapshot).length;
		const first = deferred<SessionsEventsResult>();
		const second = deferred<SessionsEventsResult>();
		const completed: SessionEventBatch = {
			cursor: cursor(4),
			events: [
				{
					event: "agent",
					payload: {
						type: "completed",
						sessionKey: KEY,
						runId: "run-1",
						ok: true,
						answer: "truncated",
						durationMs: 12,
						usage: { costUsd: 0.25 },
					},
				},
			],
		};
		const observed: string[] = [];
		teardown.push(app.client.events.on("agent-applied", (event) => observed.push(event.type)));
		server.onMethod(METHOD.sessionsEvents, ({ cursor: after }: { cursor: SessionEventCursor }) =>
			after.seq === 0 ? first.promise : after.seq === 2 ? second.promise : page([], after.seq),
		);
		const requested = server.waitForRequest(METHOD.sessionsEvents);
		server.dropConnections();
		expect((await requested).params).toMatchObject({ sessionKey: KEY, cursor: cursor(0) });
		await push(app, server, delta(3, "C"));
		await push(app, server, completed);
		await push(app, server, delta(5, "D"));
		expect(app.store.focused.bufferFor("run-1")).toBe("A");
		first.resolve(page([delta(1, "B"), { cursor: cursor(2), events: [] }], 2, true));
		await waitFor(() => server.requestsFor(METHOD.sessionsEvents).length === 2);
		expect(app.store.focused.bufferFor("run-1")).toBe("AB");
		second.resolve(page([delta(3, "C"), completed], 4));
		await waitFor(
			() => app.store.focused.eventCursor?.seq === 5 && !app.store.focused.eventRecovery,
		);
		await push(app, server, delta(1, "B"));
		await push(app, server, completed);
		const legacy = app.client.events.waitFor("chat");
		server.pushEvent("chat", {
			type: "delta",
			sessionKey: KEY,
			runId: "run-1",
			seq: 999,
			text: "duplicate legacy",
		});
		await legacy;
		expect(app.store.focused.bufferFor("run-1")).toBe("ABCD");
		expect(app.store.focused.assistantFor("run-1")?.status).toBe("done");
		expect(observed).toEqual(["completed"]);
		expect(app.store.focused.sessionCostUsd).toBe(0.25);
		expect(server.requestsFor(METHOD.sessionsSnapshot)).toHaveLength(snapshots);
		expect(app.editor.getExpandedText()).toBe("keep my draft");
		expect(server.requestsFor(METHOD.chatSend)).toHaveLength(0);
	});

	test("a gap requests replay and applies no out-of-order delta", async () => {
		const { app, server } = await boot();
		const release = deferred<SessionsEventsResult>();
		server.onMethod(METHOD.sessionsEvents, () => release.promise);
		await push(app, server, delta(2, "C"));
		await waitFor(() => server.requestsFor(METHOD.sessionsEvents).length === 1);
		expect(app.store.focused.bufferFor("run-1")).toBe("A");
		release.resolve(page([delta(1, "B"), delta(2, "C")], 2));
		await waitFor(() => !app.store.focused.eventRecovery);
		expect(app.store.focused.bufferFor("run-1")).toBe("ABC");
	});

	test("expiry installs the snapshot cursor and deduplicates buffered events", async () => {
		const { app, server } = await boot();
		server.respondWith(METHOD.sessionsEvents, { status: "cursor_expired", sessionKey: KEY });
		const release = deferred<SessionsSnapshotResult>();
		const entered = deferred<void>();
		server.onMethod(METHOD.sessionsSnapshot, () => {
			entered.resolve();
			return release.promise;
		});
		const recovering = app.sessions.resync();
		await entered.promise;
		await push(app, server, delta(3, "already in snapshot"));
		await push(app, server, delta(4, "D"));
		release.resolve(snapshot(3, "ABC"));
		await recovering;
		expect(app.store.focused.eventCursor).toEqual(cursor(4));
		expect(app.store.focused.bufferFor("run-1")).toBe("ABCD");
		expect(server.requestsFor(METHOD.sessionsEvents)).toHaveLength(1);
	});

	for (const code of ["FORBIDDEN", "INTERNAL_ERROR"]) {
		test(`${code} during replay is not snapshot success`, async () => {
			const { app, server } = await boot();
			const snapshots = server.requestsFor(METHOD.sessionsSnapshot).length;
			server.failWith(METHOD.sessionsEvents, code, "replay unavailable");
			await app.sessions.resync();
			expect(server.requestsFor(METHOD.sessionsSnapshot)).toHaveLength(snapshots);
			expect(app.store.focused.eventCursor).toEqual(cursor(0));
			expect(app.store.focused.eventRecovery).toBe(true);
			expect(app.store.focused.busy).toBe(true);
			expect(
				app.store.focused.blocks.some(
					(block) => block.kind === "notice" && block.text.includes("could not replay"),
				),
			).toBe(true);
		});
	}

	test("unsupported live versions fail closed and request a snapshot", async () => {
		const { app, server } = await boot();
		server.respondWith(METHOD.sessionsSnapshot, snapshot(7, "owner truth"));
		await push(app, server, {
			...delta(1, "must not apply"),
			cursor: { ...cursor(1), version: 2 } as unknown as SessionEventCursor,
		});
		await waitFor(() => app.store.focused.eventCursor?.seq === 7);
		expect(app.store.focused.bufferFor("run-1")).toBe("owner truth");
		expect(server.requestsFor(METHOD.sessionsEvents)).toHaveLength(0);
	});

	test("unsupported replay versions request a snapshot before applying the page", async () => {
		const { app, server } = await boot();
		server.respondWith(METHOD.sessionsEvents, {
			...page([delta(1, "unsafe")], 1),
			cursor: { ...cursor(1), version: 2 },
		});
		server.respondWith(METHOD.sessionsSnapshot, snapshot(9, "supported snapshot"));
		await app.sessions.resync();
		expect(app.store.focused.eventCursor).toEqual(cursor(9));
		expect(app.store.focused.bufferFor("run-1")).toBe("supported snapshot");
	});

	test("an unsupported snapshot cursor never installs transcript or cursor", async () => {
		const { app, server } = await boot();
		server.respondWith(METHOD.sessionsEvents, { status: "cursor_expired", sessionKey: KEY });
		server.respondWith(METHOD.sessionsSnapshot, {
			...snapshot(9, "unsafe"),
			eventCursor: { ...cursor(9), version: 2 },
		});
		await app.sessions.resync();
		expect(app.store.focused.eventCursor).toEqual(cursor(0));
		expect(app.store.focused.bufferFor("run-1")).toBe("A");
		expect(app.store.focused.eventRecovery).toBe(true);
	});

	test("another owner incarnation forces a snapshot regardless of its seq", async () => {
		const { app, server } = await boot();
		server.respondWith(METHOD.sessionsSnapshot, snapshot(0, "new owner", "owner-2"));
		await push(app, server, { ...delta(1, "unsafe"), cursor: cursor(1, "owner-2") });
		await waitFor(() => app.store.focused.eventCursor?.streamId === "owner-2");
		expect(app.store.focused.bufferFor("run-1")).toBe("new owner");
		expect(server.requestsFor(METHOD.sessionsEvents)).toHaveLength(0);
	});

	test("a malformed page commits nothing and never falls back to snapshot", async () => {
		const { app, server } = await boot();
		const snapshots = server.requestsFor(METHOD.sessionsSnapshot).length;
		server.respondWith(METHOD.sessionsEvents, page([delta(1, "B"), delta(3, "gap")], 3));
		await app.sessions.resync();
		expect(app.store.focused.eventCursor).toEqual(cursor(0));
		expect(app.store.focused.bufferFor("run-1")).toBe("A");
		expect(app.store.focused.eventRecovery).toBe(true);
		expect(server.requestsFor(METHOD.sessionsSnapshot)).toHaveLength(snapshots);
	});

	test("background replay drains one queued prompt after all pages without changing focus", async () => {
		const { app, server } = await boot();
		server.respondWith(METHOD.chatSend, { sessionKey: KEY, runId: "next-run" });
		await app.submit("first queued prompt");
		await app.submit("second queued prompt");
		const other = snapshot();
		other.sessionKey = "tui-other";
		other.identity = {
			...other.identity,
			sessionKey: "tui-other",
			sessionId: "native-2",
			runId: "other-run",
		};
		other.eventCursor = { ...cursor(0), sessionId: "native-2", streamId: "other-owner" };
		server.respondWith(METHOD.sessionsSnapshot, other);
		await app.sessions.switch("tui-other");
		app.editor.setText("other session draft");
		await app.sessions.resync(KEY);
		const original = app.store.session(KEY);
		const tail = deferred<SessionsEventsResult>();
		const completed: SessionEventBatch = {
			cursor: cursor(1),
			events: [
				{
					event: "agent",
					payload: {
						type: "completed",
						sessionKey: KEY,
						runId: "run-1",
						ok: true,
						answer: "A",
						durationMs: 1,
					},
				},
			],
		};
		server.onMethod(METHOD.sessionsEvents, ({ cursor: after }: { cursor: SessionEventCursor }) =>
			after.seq === 0 ? page([completed], 1, true) : tail.promise,
		);
		const recovering = app.sessions.resync(KEY);
		await waitFor(() => original.eventCursor?.seq === 1);
		expect(server.requestsFor(METHOD.chatSend)).toHaveLength(0);
		tail.resolve(page([], 1));
		await recovering;
		await waitFor(() => original.activeRunId === "next-run");
		expect(server.requestsFor(METHOD.chatSend)).toHaveLength(1);
		await push(app, server, completed);
		expect(server.requestsFor(METHOD.chatSend)).toHaveLength(1);
		expect(app.store.queue.items(KEY).map((item) => item.text)).toEqual(["second queued prompt"]);
		expect(app.store.focusedKey).toBe("tui-other");
		expect(app.editor.getExpandedText()).toBe("other session draft");
	});

	test("a newer replayed run prevents an earlier completion from draining the queue", async () => {
		const { app, server } = await boot();
		await app.submit("must wait for the new run");
		const completed: SessionEventBatch = {
			cursor: cursor(1),
			events: [
				{
					event: "agent",
					payload: { type: "completed", sessionKey: KEY, runId: "run-1", ok: true },
				},
			],
		};
		const started: SessionEventBatch = {
			cursor: cursor(2),
			events: [{ event: "agent", payload: { type: "started", sessionKey: KEY, runId: "run-2" } }],
		};
		server.respondWith(METHOD.sessionsEvents, page([completed, started], 2));
		await app.sessions.resync();
		expect(app.store.focused.activeRunId).toBe("run-2");
		expect(server.requestsFor(METHOD.chatSend)).toHaveLength(0);
		expect(app.store.queue.items(KEY)).toHaveLength(1);
	});
});
