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
const KEY = "tui-recovered-queue";
const teardown: Array<() => void> = [];

beforeEach(() => {
	initTheme({ colorLevel: 3 });
});
afterEach(() => {
	while (teardown.length) teardown.pop()?.();
	resetTheme();
	invalidateThemeAdapters();
});

function running(key = KEY, runId = "recovered-run"): Snapshot {
	return {
		status: "ok",
		sessionKey: key,
		identity: {
			sessionKey: key,
			sessionId: "native-owner",
			branchId: "running-leaf",
			revision: "running-revision",
			runId,
			attempt: "opaque-live-attempt",
		},
		continuation: false,
		consistency: { boundary: "stable_owner_reads", atomic: false, eventCursor: null },
		snapshot: {
			phase: "running",
			terminal: false,
			answer: { text: "partial owner answer", canonical: false, truncated: false },
			messages: [{ id: "running-leaf", role: "user", content: "original prompt", timestampMs: 1 }],
			actions: [],
			approvals: { status: "ok", items: [] },
			children: { status: "ok", items: [] },
			processes: { status: "ok", items: [] },
			todos: { status: "ok", items: [] },
			plan: { status: "ok", value: { mode: "code" } },
		},
	};
}

function terminal(runId = "recovered-run"): Snapshot {
	const result = running(KEY, runId);
	result.identity = {
		...result.identity,
		branchId: "completed-leaf",
		revision: "completed-revision",
		attempt: runId,
	};
	// This is the explicit authenticated owner proof, not derived by echoing
	// request parameters. Server regressions exercise its journal/provenance rules.
	result.continuation = true;
	result.snapshot.phase = "completed";
	result.snapshot.terminal = true;
	result.snapshot.answer = { text: "canonical terminal answer", canonical: true, truncated: false };
	return result;
}

function deferred<T>() {
	let resolve!: (value: T) => void;
	const promise = new Promise<T>((done) => {
		resolve = done;
	});
	return { promise, resolve };
}

async function boot(initial = running(), snapshots = true) {
	const server = await FakeControlPlane.start({
		methods: snapshots ? [...DEFAULT_METHODS, "sessions.snapshot"] : DEFAULT_METHODS,
	});
	teardown.push(() => server.stop());
	server.respondWith("chat.history", { messages: [] });
	server.respondWith("sessions.snapshot", initial);
	server.respondWith("chat.send", { sessionKey: KEY, runId: "next-run" });
	const client = new ControlPlaneClient({
		url: server.url,
		socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
	});
	const app = new AppShell({
		url: server.url,
		sessionKey: KEY,
		client,
		terminal: new MemoryTerminal(),
		smoothStreaming: false,
		readBranch: async () => null,
	});
	teardown.push(() => app.stop());
	await app.start();
	return { app, server };
}

function prompts(server: FakeControlPlane) {
	return server.requestsFor("chat.send").map((request) => pickString(request.params, "prompt"));
}

async function preview(app: AppShell, server: FakeControlPlane, runId = "recovered-run") {
	const received = app.client.events.waitFor("agent");
	server.pushEvent("agent", {
		type: "completed",
		sessionKey: KEY,
		runId,
		ok: true,
		answer: "unverified preview",
	});
	await received;
}

describe("recovered terminal queue advancement", () => {
	test("live completion waits for canonical owner truth, sends one local head, and old repeats cannot advance its next run", async () => {
		const { app, server } = await boot();
		await app.submit("known unsent followup");
		await app.submit("wait for the followup run");
		expect(prompts(server)).toEqual([]);
		expect(app.store.queue.items(KEY).map((item) => item.state)).toEqual([
			"queued-local",
			"queued-local",
		]);
		const entered = deferred<void>();
		const release = deferred<Snapshot>();
		server.onMethod("sessions.snapshot", () => {
			entered.resolve();
			return release.promise;
		});
		await preview(app, server);
		await entered.promise;
		expect(prompts(server)).toEqual([]);
		expect(app.store.focused.busy).toBe(true);
		release.resolve(terminal());
		await app.sessions.resync();
		await waitFor(() => app.store.focused.activeRunId === "next-run", {
			what: "acknowledged recovered queue send",
		});
		expect(prompts(server)).toEqual(["known unsent followup"]);
		expect(renderPlain(app.chatContainer.render(80))).toContain("canonical terminal answer");
		expect(app.store.queue.items(KEY).map((item) => item.text)).toEqual([
			"wait for the followup run",
		]);
		expect(server.requestsFor("sessions.snapshot").at(-1)?.params).toMatchObject({
			continuationFrom: { identity: running().identity, runId: "recovered-run" },
		});

		server.respondWith("sessions.snapshot", terminal());
		await app.sessions.resync();
		await app.sessions.resync();
		await preview(app, server);
		await app.sessions.resync();
		expect(prompts(server)).toEqual(["known unsent followup"]);
		expect(app.store.focused.activeRunId).toBe("next-run");
		expect(app.store.focused.busy).toBe(true);
	});

	test("an acknowledged new turn after recovery needs no intermediate running snapshot", async () => {
		const idle = terminal("previous-run");
		idle.continuation = false;
		const { app, server } = await boot(idle);
		await app.submit("acknowledged new turn");
		await app.submit("queued behind acknowledged turn");
		server.respondWith("chat.send", { sessionKey: KEY, runId: "followup-run" });
		server.respondWith("sessions.snapshot", terminal("next-run"));
		await preview(app, server, "next-run");
		await app.sessions.resync();
		await waitFor(() => app.store.focused.activeRunId === "followup-run", {
			what: "new turn's queued followup",
		});
		expect(prompts(server)).toEqual(["acknowledged new turn", "queued behind acknowledged turn"]);
	});

	for (const receipt of ["missing-run-id", "outcome-unknown"] as const) {
		test(`${receipt} cannot replay the send or consume the following local head on repeated terminal reads`, async () => {
			const { app, server } = await boot();
			await app.submit("send only once");
			await app.submit("do not advance without a new verified run");
			if (receipt === "missing-run-id") server.respondWith("chat.send", {});
			else server.failWith("chat.send", "OUTCOME_UNKNOWN", "submission may have been accepted");
			server.respondWith("sessions.snapshot", terminal());
			await app.sessions.resync();
			await waitFor(() => server.requestsFor("chat.send").length === 1, {
				what: "single attempted queue send",
			});
			await app.sessions.resync();
			await preview(app, server);
			await app.sessions.resync();
			expect(prompts(server)).toEqual(["send only once"]);
			expect(app.store.queue.items(KEY).map((item) => item.text)).toEqual([
				"do not advance without a new verified run",
			]);
		});
	}

	test("the production unknown-submission receipt stays review-only ahead of genuinely local work", async () => {
		const { app, server } = await boot();
		server.failWith("chat.send", "UNAVAILABLE", "Chat submission outcome is unknown", {
			code: "SUBMISSION_OUTCOME_UNKNOWN",
			runId: "uncertain-fixed-id",
			sessionKey: KEY,
			retrySafe: false,
		});
		await app.sendPrompt("uncertain steering submission", { mode: "steer" });
		await app.submit("genuinely local followup");
		expect(app.store.queue.items(KEY).map((item) => item.state)).toEqual([
			"needs-review",
			"queued-local",
		]);
		server.respondWith("sessions.snapshot", terminal());
		await app.sessions.resync();
		await app.sessions.resync();
		expect(prompts(server)).toEqual(["uncertain steering submission"]);
		expect(app.store.queue.items(KEY).map((item) => item.text)).toEqual([
			"uncertain steering submission",
			"genuinely local followup",
		]);
	});

	for (const state of ["needs-review", "waiting-connection"] as const) {
		test(`${state} head remains untouched, including the known-unsent item behind it`, async () => {
			const { app, server } = await boot();
			app.store.queue.push(KEY, "receipt is not ours to replay", state);
			await app.submit("known unsent but not at the head");
			server.respondWith("sessions.snapshot", terminal());
			await app.sessions.resync();
			await app.sessions.resync();
			expect(prompts(server)).toEqual([]);
			expect(app.store.queue.items(KEY).map((item) => item.state)).toEqual([state, "queued-local"]);
		});
	}

	const ineligible: Array<[string, (result: Snapshot) => void]> = [
		[
			"another run",
			(result) => {
				result.identity.runId = "foreign-run";
				result.continuation = false;
			},
		],
		[
			"another native owner",
			(result) => {
				result.identity.sessionId = "replacement-owner";
				result.continuation = false;
			},
		],
		[
			"another live attempt",
			(result) => {
				result.identity.attempt = "foreign-live-attempt";
				result.continuation = false;
			},
		],
		[
			"abandoned branch",
			(result) => {
				result.identity.branchId = "non-descendant-leaf";
				result.continuation = false;
			},
		],
		[
			"another routing key",
			(result) => {
				result.sessionKey = "foreign-key";
				result.identity.sessionKey = "foreign-key";
				result.continuation = false;
			},
		],
		[
			"unknown owner phase",
			(result) => {
				result.snapshot.phase = "unknown";
				result.snapshot.terminal = false;
				result.continuation = false;
			},
		],
		[
			"still running",
			(result) => {
				result.snapshot.phase = "running";
				result.snapshot.terminal = false;
				result.continuation = false;
			},
		],
		[
			"noncanonical terminal preview",
			(result) => {
				result.snapshot.answer.canonical = false;
			},
		],
		[
			"no owner continuation proof",
			(result) => {
				delete result.continuation;
			},
		],
		[
			"misbound run despite a proof flag",
			(result) => {
				result.identity.runId = "foreign-run";
			},
		],
		[
			"misbound owner despite a proof flag",
			(result) => {
				result.identity.sessionId = "replacement-owner";
			},
		],
	];
	for (const [name, change] of ineligible) {
		test(`${name} does not submit a queued-local prompt`, async () => {
			const { app, server } = await boot();
			await app.submit("must stay local");
			const result = terminal();
			change(result);
			server.respondWith("sessions.snapshot", result);
			await app.sessions.resync();
			expect(prompts(server)).toEqual([]);
			expect(app.store.queue.items(KEY).map((item) => item.text)).toEqual(["must stay local"]);
		});
	}

	test("an unavailable owner and retry exhaustion do not invent completion", async () => {
		const { app, server } = await boot();
		await app.submit("must stay local");
		server.failWith("sessions.snapshot", "UNAVAILABLE", "owner unavailable");
		await app.sessions.resync();
		server.respondWith("sessions.snapshot", {
			status: "retry",
			sessionKey: KEY,
			identity: running().identity,
			reason: "snapshot_raced",
			retrySafe: true,
		});
		await app.sessions.resync();
		expect(prompts(server)).toEqual([]);
		expect(app.store.focused.busy).toBe(true);
		expect(app.store.queue.items(KEY)).toHaveLength(1);
	});

	test("leaving and reselecting the same key fences a late terminal read", async () => {
		const { app, server } = await boot();
		await app.submit("keep queued in the original selection");
		const entered = deferred<void>();
		const release = deferred<Snapshot>();
		let first = true;
		server.onMethod("sessions.snapshot", ({ sessionKey }: { sessionKey: string }) => {
			if (first) {
				first = false;
				entered.resolve();
				return release.promise;
			}
			return running(sessionKey);
		});
		const oldRead = app.sessions.resync();
		await entered.promise;
		await app.sessions.switch("other-key");
		await app.sessions.switch(KEY);
		release.resolve(terminal());
		await oldRead;
		expect(prompts(server)).toEqual([]);
		expect(app.store.focused.activeRunId).toBe("recovered-run");
		expect(app.store.focused.busy).toBe(true);
		expect(app.store.queue.items(KEY)).toHaveLength(1);
	});

	test("a new local send receipt supersedes an in-flight terminal projection without an agent event", async () => {
		const { app, server } = await boot();
		await app.submit("keep queued behind the selected run");
		const entered = deferred<void>();
		const release = deferred<Snapshot>();
		let first = true;
		server.onMethod("sessions.snapshot", () => {
			if (first) {
				first = false;
				entered.resolve();
				return release.promise;
			}
			return running(KEY, "next-run");
		});
		const recovery = app.sessions.resync();
		await entered.promise;
		await app.sendPrompt("explicit redirect", { mode: "redirect" });
		release.resolve(terminal());
		await recovery;
		expect(prompts(server)).toEqual(["explicit redirect"]);
		expect(app.store.focused.activeRunId).toBe("next-run");
		expect(app.store.focused.busy).toBe(true);
		expect(app.store.queue.items(KEY)).toHaveLength(1);
	});

	test("a newer accepted branch/revision projection supersedes a pending read for the same run", async () => {
		const { app, server } = await boot();
		await app.submit("keep queued on the newly selected branch");
		const entered = deferred<void>();
		const release = deferred<Snapshot>();
		const selected = running();
		selected.identity = {
			...selected.identity,
			branchId: "new-selected-leaf",
			revision: "new-selected-revision",
		};
		let first = true;
		server.onMethod("sessions.snapshot", () => {
			if (first) {
				first = false;
				entered.resolve();
				return release.promise;
			}
			return selected;
		});
		const recovery = app.sessions.resync();
		await entered.promise;
		// Fault injection at the mutable projection seam: another owner install
		// changed branch/revision without changing the acknowledged logical run.
		app.store.focused.snapshotIdentity = selected.identity;
		release.resolve(terminal());
		await recovery;
		expect(prompts(server)).toEqual([]);
		expect(app.store.focused.snapshotIdentity).toEqual(selected.identity);
		expect(app.store.focused.busy).toBe(true);
		expect(app.store.queue.items(KEY)).toHaveLength(1);
	});

	test("ordinary non-recovery completion still drains one item", async () => {
		const { app, server } = await boot(running(), false);
		await app.submit("ordinary first turn");
		await app.submit("ordinary followup");
		server.respondWith("chat.send", { sessionKey: KEY, runId: "ordinary-followup-run" });
		await preview(app, server, "next-run");
		await waitFor(() => app.store.focused.activeRunId === "ordinary-followup-run", {
			what: "ordinary completion drain",
		});
		expect(prompts(server)).toEqual(["ordinary first turn", "ordinary followup"]);
	});
});
