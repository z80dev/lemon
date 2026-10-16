/**
 * Cumulative session cost in the status bar, through the real shell and fake
 * control plane: live events, snapshot-managed recovery, resumed history and
 * events lost to a disconnect. Unknown cost is never shown as zero.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { AppShell } from "../../src/app.ts";
import { DEFAULT_METHODS, FakeControlPlane } from "../../src/dev/fake-server.ts";
import {
	estimatedContextFixture,
	reportedContextFixture,
} from "../../src/dev/fixtures/context-fixtures.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import type { SessionsSnapshotResult } from "../../src/protocol/types.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal, stripAnsi } from "../helpers/memory-terminal.ts";
import { waitFor } from "../helpers/wait.ts";

type Snapshot = Extract<SessionsSnapshotResult, { status: "ok" }>;
const KEY = "tui-cost";
const teardown: Array<() => void> = [];

beforeEach(() => {
	initTheme({ colorLevel: 3 });
});
afterEach(() => {
	while (teardown.length) teardown.pop()?.();
	resetTheme();
	invalidateThemeAdapters();
});

const HISTORY = [
	{ id: "m1", role: "user", content: "earlier question", timestampMs: 1000 },
	{ id: "m2", role: "assistant", content: "earlier answer", timestampMs: 2000 },
];

function snapshot(runId: string | undefined, terminal: boolean, messages = 0): Snapshot {
	return {
		status: "ok",
		sessionKey: KEY,
		identity: {
			sessionKey: KEY,
			sessionId: "native-owner",
			branchId: `leaf-${runId ?? "idle"}`,
			revision: `revision-${runId ?? "idle"}`,
			...(runId ? { runId, attempt: runId } : {}),
		},
		continuation: terminal,
		consistency: { boundary: "stable_owner_reads", atomic: false, eventCursor: null },
		snapshot: {
			phase: terminal ? "completed" : "running",
			terminal,
			answer: { text: terminal ? "canonical answer" : "", canonical: terminal, truncated: false },
			messages: HISTORY.slice(0, messages),
			actions: [],
			approvals: { status: "ok", items: [] },
			children: { status: "ok", items: [] },
			processes: { status: "ok", items: [] },
			todos: { status: "ok", items: [] },
			plan: { status: "ok", value: { mode: "code" } },
		},
	} as Snapshot;
}

async function boot(
	options: {
		snapshots?: Snapshot;
		history?: typeof HISTORY;
		context?: Record<string, unknown>;
	} = {},
) {
	const server = await FakeControlPlane.start({
		methods: options.snapshots ? [...DEFAULT_METHODS, "sessions.snapshot"] : DEFAULT_METHODS,
	});
	teardown.push(() => server.stop());
	server.respondWith("chat.history", { messages: options.history ?? [] });
	server.respondWith("sessions.active.list", { sessions: [] });
	server.respondWith("exec.approvals.get", { approvals: [] });
	server.respondWith("usage.status", { summary: { totalTokens: 1 } });
	if (options.snapshots) server.respondWith("sessions.snapshot", options.snapshots);
	if (options.context) server.serveSessionContext({ [KEY]: options.context });
	const client = new ControlPlaneClient({
		url: server.url,
		socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
	});
	const app = new AppShell({
		url: server.url,
		sessionKey: KEY,
		version: "test",
		client,
		terminal: new MemoryTerminal(),
		cwd: "/work/project",
		smoothStreaming: false,
		readBranch: async () => null,
	});
	teardown.push(() => app.stop());
	await app.start();
	return { app, server };
}

const status = (app: AppShell) => stripAnsi(app.statusBar.render(200)[0] ?? "");

async function complete(app: AppShell, server: FakeControlPlane, runId: string, usage?: object) {
	const received = app.client.events.waitFor("agent");
	server.pushEvent("agent", {
		type: "completed",
		sessionKey: KEY,
		runId,
		ok: true,
		answer: "done",
		...(usage ? { usage } : {}),
	});
	await received;
}

describe("session cost in the status bar", () => {
	test("a fresh session totals priced runs exactly and shows unknown, not $0.00, without cost data", async () => {
		const { app, server } = await boot();
		expect(status(app)).toContain("session cost unknown");
		await complete(app, server, "run-1", { totalTokens: 10, costUsd: 0.25 });
		expect(status(app)).toContain("session $0.25");
		await complete(app, server, "run-2", { totalTokens: 10, costUsd: 0.5 });
		expect(status(app)).toContain("session $0.75");
		// A replayed completion never counts twice.
		await complete(app, server, "run-2", { totalTokens: 10, costUsd: 0.5 });
		expect(status(app)).toContain("session $0.75");
		await complete(app, server, "run-3", { totalTokens: 10 });
		expect(status(app)).toContain("session ≥$0.75");
	});

	test("a run with no cost data leaves the total unknown", async () => {
		const { app, server } = await boot();
		await complete(app, server, "run-1", { totalTokens: 10 });
		expect(status(app)).toContain("session cost unknown");
		expect(status(app)).not.toContain("session $0");
		expect(status(app)).not.toContain("session ≥$0");
	});

	test("a snapshot-managed session still advances after each priced run and never double counts recoveries", async () => {
		const { app, server } = await boot({ snapshots: snapshot("run-1", false) });
		expect(app.store.focused.snapshotIdentity).toBeDefined();
		server.respondWith("sessions.snapshot", snapshot("run-1", true));
		await complete(app, server, "run-1", { totalTokens: 10, costUsd: 0.25 });
		await app.sessions.resync();
		await waitFor(() => status(app).includes("session $0.25"), { what: "first run cost" });
		// Repeated owner reads of the same terminal run add nothing.
		await app.sessions.resync();
		await app.sessions.resync();
		expect(status(app)).toContain("session $0.25");

		server.respondWith("sessions.snapshot", snapshot("run-2", true));
		await complete(app, server, "run-2", { totalTokens: 10, costUsd: 0.5 });
		await app.sessions.resync();
		await waitFor(() => status(app).includes("session $0.75"), { what: "second run cost" });
		await complete(app, server, "run-2", { totalTokens: 10, costUsd: 0.5 });
		await app.sessions.resync();
		expect(status(app)).toContain("session $0.75");
	});

	test("a terminal run recovered without its completion event is a lower bound, until the event arrives", async () => {
		const { app, server } = await boot({ snapshots: snapshot("run-1", false) });
		await complete(app, server, "run-1", { totalTokens: 10, costUsd: 0.25 });
		server.respondWith("sessions.snapshot", snapshot("run-2", true));
		await app.sessions.resync();
		expect(status(app)).toContain("session ≥$0.25");
		await complete(app, server, "run-2", { totalTokens: 10, costUsd: 0.5 });
		await app.sessions.resync();
		await waitFor(
			() => status(app).includes("session ≥$0.75") || status(app).includes("session $0.75"),
			{
				what: "late completion folded in",
			},
		);
		expect(status(app)).toContain("session $0.75");
	});

	test("resuming stored history with no ledger is a lower bound, never an exact total", async () => {
		const { app, server } = await boot({ history: HISTORY, context: estimatedContextFixture(KEY) });
		await app.methods.sessionsActiveList();
		expect(status(app)).toContain("session cost unknown");
		await complete(app, server, "run-1", { totalTokens: 10, costUsd: 0.25 });
		expect(status(app)).toContain("session ≥$0.25");
	});

	test("resuming stored history seeds the daemon's ledger as a lower bound and adds new runs", async () => {
		const { app, server } = await boot({ history: HISTORY, context: reportedContextFixture(KEY) });
		await waitFor(() => status(app).includes("session ≥$0.42"), { what: "ledger seed" });
		await complete(app, server, "run-1", { totalTokens: 10, costUsd: 0.25 });
		expect(status(app)).toContain("session ≥$0.67");
	});

	test("a terminal run already in the ledger seed is not added again by its late completion", async () => {
		const { app, server } = await boot({
			snapshots: snapshot("run-1", true, 2),
			history: HISTORY,
			context: reportedContextFixture(KEY),
		});
		await waitFor(() => status(app).includes("session ≥$0.42"), { what: "ledger seed" });
		await complete(app, server, "run-1", { totalTokens: 10, costUsd: 0.42 });
		expect(status(app)).toContain("session ≥$0.42");
		expect(status(app)).not.toContain("0.84");
		await complete(app, server, "run-2", { totalTokens: 10, costUsd: 0.25 });
		expect(status(app)).toContain("session ≥$0.67");
	});

	test("resuming a snapshot-managed session with history is a lower bound", async () => {
		const { app, server } = await boot({ snapshots: snapshot(undefined, false, 2) });
		await complete(app, server, "run-1", { totalTokens: 10, costUsd: 0.25 });
		await waitFor(() => status(app).includes("session ≥$0.25"), { what: "partial total" });
		expect(status(app)).not.toContain("session $0.25");
	});

	test("costs missed during a disconnect make the total a lower bound; a session's own recovery does not", async () => {
		const { app, server } = await boot();
		await complete(app, server, "run-1", { totalTokens: 10, costUsd: 0.25 });
		const hello = app.client.helloOk;
		if (!hello) throw new Error("not connected");
		app.client.events.emit("resync-needed", { hello, sessionKey: KEY });
		expect(status(app)).toContain("session $0.25");
		app.client.events.emit("resync-needed", { hello });
		await waitFor(() => status(app).includes("session ≥$0.25"), { what: "lower bound" });
	});
});
