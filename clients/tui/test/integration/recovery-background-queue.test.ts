import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { AppShell } from "../../src/app.ts";
import { pickString } from "../../src/commands/format.ts";
import { DEFAULT_METHODS, FakeControlPlane } from "../../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import type { SessionsSnapshotResult } from "../../src/protocol/types.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal, renderPlain } from "../helpers/memory-terminal.ts";
import { waitFor } from "../helpers/wait.ts";

type Snapshot = Extract<SessionsSnapshotResult, { status: "ok" }>;
const A = "tui-background-a";
const B = "tui-focused-b";
const C = "tui-focused-c";
const teardown: Array<() => void> = [];

beforeEach(() => {
	initTheme({ colorLevel: 3 });
});
afterEach(() => {
	while (teardown.length) teardown.pop()?.();
	resetTheme();
	invalidateThemeAdapters();
});

function running(key: string, runId = `run-${key}`): Snapshot {
	return {
		status: "ok",
		sessionKey: key,
		identity: {
			sessionKey: key,
			sessionId: `native-${key}`,
			branchId: `leaf-${key}`,
			revision: `revision-${key}`,
			runId,
			attempt: `live-${runId}`,
		},
		continuation: false,
		consistency: { boundary: "stable_owner_reads", atomic: false, eventCursor: null },
		snapshot: {
			phase: "running",
			terminal: false,
			answer: { text: `partial owner answer for ${key}`, canonical: false, truncated: false },
			messages: [
				{ id: `leaf-${key}`, role: "user", content: `original prompt for ${key}`, timestampMs: 1 },
			],
			actions: [],
			approvals: { status: "ok", items: [] },
			children: { status: "ok", items: [] },
			processes: { status: "ok", items: [] },
			todos: { status: "ok", items: [] },
			plan: { status: "ok", value: { mode: "code" } },
		},
	};
}

function terminalA(): Snapshot {
	const result = running(A);
	result.identity = {
		...result.identity,
		branchId: "terminal-leaf-a",
		revision: "terminal-revision-a",
		attempt: result.identity.runId,
	};
	result.continuation = true;
	result.snapshot.phase = "completed";
	result.snapshot.terminal = true;
	result.snapshot.answer = {
		text: "canonical terminal answer for background A",
		canonical: true,
		truncated: false,
	};
	return result;
}

function deferred<T>() {
	let resolve!: (value: T) => void;
	const promise = new Promise<T>((done) => {
		resolve = done;
	});
	return { promise, resolve };
}

async function boot() {
	const server = await FakeControlPlane.start({
		methods: [...DEFAULT_METHODS, "sessions.snapshot"],
	});
	teardown.push(() => server.stop());
	const snapshots = new Map<string, Snapshot>([
		[A, running(A)],
		[B, running(B)],
		[C, running(C)],
	]);
	server.onMethod("sessions.snapshot", (params: { sessionKey: string }) => {
		const result = snapshots.get(params.sessionKey);
		if (!result) throw new Error("fixture has no owner for this session");
		return result;
	});
	server.respondWith("chat.send", { sessionKey: A, runId: "next-run-a" });
	server.respondWith("sessions.delete", { deleted: true });
	const client = new ControlPlaneClient({
		url: server.url,
		socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
	});
	const app = new AppShell({
		url: server.url,
		sessionKey: A,
		client,
		terminal: new MemoryTerminal(),
		smoothStreaming: false,
		readBranch: async () => null,
	});
	teardown.push(() => app.stop());
	await app.start();
	await app.submit("known-unsent followup for A");
	await app.submit("second followup waits for A's next run");
	return { app, server, snapshots };
}

function sends(server: FakeControlPlane) {
	return server.requestsFor("chat.send").map((request) => ({
		sessionKey: pickString(request.params, "sessionKey"),
		prompt: pickString(request.params, "prompt"),
	}));
}

async function completeA(app: AppShell, server: FakeControlPlane) {
	const received = app.client.events.waitFor("agent");
	server.pushEvent("agent", {
		type: "completed",
		sessionKey: A,
		runId: `run-${A}`,
		ok: true,
		answer: "unverified terminal preview",
	});
	await received;
}

function focusedText(app: AppShell) {
	return renderPlain(app.chatContainer.render(80));
}

describe("background recovered session queues", () => {
	test("A's verified completion drains A once while B keeps its run, draft and transcript", async () => {
		const { app, server, snapshots } = await boot();
		await app.sessions.switch(B);
		await app.sessions.resync(A);
		app.editor.setText("B's unsent draft");
		const entered = deferred<void>();
		const release = deferred<Snapshot>();
		server.onMethod("sessions.snapshot", (params: { sessionKey: string }) => {
			if (params.sessionKey === A) {
				entered.resolve();
				return release.promise;
			}
			return snapshots.get(params.sessionKey);
		});
		await completeA(app, server);
		await entered.promise;
		expect(sends(server)).toEqual([]);
		// A's read and focused B's read must not invalidate one another.
		await app.sessions.resync(B);
		const beforeB = focusedText(app);
		const clearScrollback: boolean[] = [];
		const original = app.tui.requestRender.bind(app.tui);
		app.tui.requestRender = (force = false, options?: { clearScrollback?: boolean }) => {
			if (options?.clearScrollback) clearScrollback.push(true);
			original(force, options);
		};
		release.resolve(terminalA());
		await app.sessions.resync(A);
		await waitFor(() => app.store.sessions.get(A)?.activeRunId === "next-run-a", {
			what: "background A's acknowledged queue drain",
		});
		expect(sends(server)).toEqual([{ sessionKey: A, prompt: "known-unsent followup for A" }]);
		expect(app.sessionKey).toBe(B);
		expect(app.store.focused.activeRunId).toBe(`run-${B}`);
		expect(app.store.focused.busy).toBe(true);
		expect(app.editor.getExpandedText()).toBe("B's unsent draft");
		expect(focusedText(app)).toBe(beforeB);
		expect(clearScrollback).toEqual([]);
		expect(app.store.queue.items(A).map((item) => item.text)).toEqual([
			"second followup waits for A's next run",
		]);
		expect(app.store.queue.items(B)).toEqual([]);

		// Old canonical reads cannot advance the next active run, even unfocused.
		await app.sessions.resync(A);
		await completeA(app, server);
		await app.sessions.resync(A);
		expect(sends(server)).toHaveLength(1);
		expect(app.store.sessions.get(A)?.activeRunId).toBe("next-run-a");
		server.onMethod("sessions.snapshot", (params: { sessionKey: string }) =>
			params.sessionKey === A ? running(A, "next-run-a") : snapshots.get(params.sessionKey),
		);
		await app.sessions.resync(A);
		await completeA(app, server);
		await app.sessions.resync(A);
		expect(sends(server)).toHaveLength(1);
		expect(app.store.sessions.get(A)?.busy).toBe(true);
		expect(focusedText(app)).toBe(beforeB);
		expect(clearScrollback).toEqual([]);

		const nextTerminal = terminalA();
		nextTerminal.identity = {
			...nextTerminal.identity,
			runId: "next-run-a",
			attempt: "next-run-a",
			branchId: "next-terminal-leaf",
			revision: "next-terminal-revision",
		};
		server.onMethod("sessions.snapshot", (params: { sessionKey: string }) =>
			params.sessionKey === A ? nextTerminal : snapshots.get(params.sessionKey),
		);
		server.respondWith("chat.send", { sessionKey: A, runId: "third-run-a" });
		const receivedNext = app.client.events.waitFor("agent");
		server.pushEvent("agent", {
			type: "completed",
			sessionKey: A,
			runId: "next-run-a",
			ok: true,
			answer: "another unverified preview",
		});
		await receivedNext;
		await app.sessions.resync(A);
		await waitFor(() => app.store.sessions.get(A)?.activeRunId === "third-run-a", {
			what: "the next verified background completion",
		});
		expect(sends(server)).toEqual([
			{ sessionKey: A, prompt: "known-unsent followup for A" },
			{ sessionKey: A, prompt: "second followup waits for A's next run" },
		]);
		expect(app.store.queue.items(A)).toEqual([]);
		expect(app.sessionKey).toBe(B);
		expect(app.editor.getExpandedText()).toBe("B's unsent draft");
		expect(focusedText(app)).toBe(beforeB);
		expect(clearScrollback).toEqual([]);
	});

	test("reconnect recovers a missed terminal for queued A without selecting it", async () => {
		const { app, server, snapshots } = await boot();
		await app.sessions.switch(B);
		await app.sessions.resync(A);
		app.editor.setText("keep B draft across reconnect");
		const offline = app.client.events.waitFor("state");
		const reconnected = app.client.events.waitFor("resync-needed");
		server.dropConnections();
		expect((await offline).state).not.toBe("online");
		snapshots.set(A, terminalA());
		await reconnected;
		await app.sessions.resync(A);
		await app.sessions.resync(B);
		await waitFor(() => app.store.sessions.get(A)?.activeRunId === "next-run-a", {
			what: "reconnect drain for background A",
		});
		expect(sends(server)).toEqual([{ sessionKey: A, prompt: "known-unsent followup for A" }]);
		expect(app.sessionKey).toBe(B);
		expect(app.editor.getExpandedText()).toBe("keep B draft across reconnect");
		expect(app.store.focused.activeRunId).toBe(`run-${B}`);
	});

	test("a keyed background loss signal refreshes A, not unrelated focused B", async () => {
		const { app, server, snapshots } = await boot();
		await app.sessions.switch(B);
		await app.sessions.resync(A);
		const beforeBReads = server
			.requestsFor("sessions.snapshot")
			.filter((request) => pickString(request.params, "sessionKey") === B).length;
		const beforeB = focusedText(app);
		snapshots.set(A, terminalA());
		const received = app.client.events.waitFor("resync-needed");
		server.pushEvent("stream.resync", { reason: "overflow", sessionKey: A });
		await received;
		await app.sessions.resync(A);
		await waitFor(() => app.store.sessions.get(A)?.activeRunId === "next-run-a", {
			what: "keyed background overflow recovery",
		});
		expect(sends(server)).toHaveLength(1);
		expect(
			server
				.requestsFor("sessions.snapshot")
				.filter((request) => pickString(request.params, "sessionKey") === B),
		).toHaveLength(beforeBReads);
		expect(focusedText(app)).toBe(beforeB);
	});

	test("selecting A supersedes its old background read; selecting B again cannot revive it", async () => {
		const { app, server, snapshots } = await boot();
		await app.sessions.switch(B);
		await app.sessions.resync(A);
		app.editor.setText("saved B draft");
		const entered = deferred<void>();
		const release = deferred<Snapshot>();
		let held = false;
		server.onMethod("sessions.snapshot", (params: { sessionKey: string }) => {
			if (params.sessionKey === A && !held) {
				held = true;
				entered.resolve();
				return release.promise;
			}
			return snapshots.get(params.sessionKey);
		});
		const abandoned = app.sessions.resync(A);
		await entered.promise;
		await app.sessions.switch(A);
		await app.sessions.switch(B);
		await app.sessions.resync(A);
		release.resolve(terminalA());
		await abandoned;
		expect(sends(server)).toEqual([]);
		expect(app.store.sessions.get(A)?.busy).toBe(true);
		expect(app.store.sessions.get(A)?.activeRunId).toBe(`run-${A}`);
		expect(app.sessionKey).toBe(B);
		expect(app.editor.getExpandedText()).toBe("saved B draft");
		expect(app.store.queue.items(A)).toHaveLength(2);
	});

	test("a focused A read hands off to independently fenced background recovery when focus moves to B", async () => {
		const { app, server, snapshots } = await boot();
		const entered = deferred<void>();
		const release = deferred<Snapshot>();
		let held = false;
		server.onMethod("sessions.snapshot", (params: { sessionKey: string }) => {
			if (params.sessionKey === A && !held) {
				held = true;
				entered.resolve();
				return release.promise;
			}
			return params.sessionKey === A ? terminalA() : snapshots.get(params.sessionKey);
		});
		const abandoned = app.sessions.resync();
		await entered.promise;
		await app.sessions.switch(B);
		await waitFor(() => app.store.sessions.get(A)?.activeRunId === "next-run-a", {
			what: "background handoff drain",
		});
		release.resolve(terminalA());
		await abandoned;
		expect(sends(server)).toHaveLength(1);
		expect(app.sessionKey).toBe(B);
		expect(app.store.focused.activeRunId).toBe(`run-${B}`);
		expect(app.store.queue.items(A)).toHaveLength(1);
	});

	test("switching between foreign B and C does not cancel A's independent owner read", async () => {
		const { app, server, snapshots } = await boot();
		await app.sessions.switch(B);
		await app.sessions.resync(A);
		const entered = deferred<void>();
		const release = deferred<Snapshot>();
		server.onMethod("sessions.snapshot", (params: { sessionKey: string }) => {
			if (params.sessionKey === A) {
				entered.resolve();
				return release.promise;
			}
			return snapshots.get(params.sessionKey);
		});
		const background = app.sessions.resync(A);
		await entered.promise;
		await app.sessions.switch(C);
		app.editor.setText("C draft");
		release.resolve(terminalA());
		await background;
		await waitFor(() => app.store.sessions.get(A)?.activeRunId === "next-run-a", {
			what: "A drain independent of foreign focus changes",
		});
		expect(sends(server)).toHaveLength(1);
		expect(app.sessionKey).toBe(C);
		expect(app.editor.getExpandedText()).toBe("C draft");
		expect(app.store.focused.activeRunId).toBe(`run-${C}`);
	});

	for (const failure of [
		"running",
		"unavailable",
		"unknown",
		"unproven-branch",
		"unproven-attempt",
		"foreign-owner",
		"foreign-run",
		"unknown-receipt",
	] as const) {
		test(`background ${failure} leaves A's queue local and B untouched`, async () => {
			const { app, server, snapshots } = await boot();
			await app.sessions.switch(B);
			await app.sessions.resync(A);
			app.editor.setText("B remains the user's draft");
			const beforeB = focusedText(app);
			const result = terminalA();
			if (failure === "running") snapshots.set(A, running(A));
			else if (failure === "unavailable")
				server.failWith("sessions.snapshot", "UNAVAILABLE", "owner unavailable");
			else if (failure === "unknown-receipt") {
				const head = app.store.queue.shift(A);
				if (!head) throw new Error("missing queued fixture head");
				app.store.queue.restoreForReview(A, head);
				snapshots.set(A, result);
			} else {
				result.continuation = false;
				if (failure === "unknown") {
					result.snapshot.phase = "unknown";
					result.snapshot.terminal = false;
				}
				if (failure === "unproven-branch") result.identity.branchId = "abandoned-leaf";
				if (failure === "unproven-attempt") result.identity.attempt = "foreign-live-attempt";
				if (failure === "foreign-owner") result.identity.sessionId = "foreign-native-owner";
				if (failure === "foreign-run") result.identity.runId = "foreign-logical-run";
				snapshots.set(A, result);
			}
			await completeA(app, server);
			await app.sessions.resync(A);
			expect(sends(server)).toEqual([]);
			expect(app.store.queue.items(A)).toHaveLength(2);
			expect(app.sessionKey).toBe(B);
			expect(app.editor.getExpandedText()).toBe("B remains the user's draft");
			expect(focusedText(app)).toBe(beforeB);
		});
	}

	test("closing background A fences its pending response without restoring the removed session", async () => {
		const { app, server, snapshots } = await boot();
		await app.sessions.switch(B);
		await app.sessions.resync(A);
		const entered = deferred<void>();
		const release = deferred<Snapshot>();
		server.onMethod("sessions.snapshot", (params: { sessionKey: string }) => {
			if (params.sessionKey === A) {
				entered.resolve();
				return release.promise;
			}
			return snapshots.get(params.sessionKey);
		});
		const pending = app.sessions.resync(A);
		await entered.promise;
		await app.sessions.close(A, { confirmed: true });
		release.resolve(terminalA());
		await pending;
		expect(sends(server)).toEqual([]);
		expect(app.store.sessions.has(A)).toBe(false);
		expect(app.sessionKey).toBe(B);
	});
});
