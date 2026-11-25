import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { AppShell } from "../../src/app.ts";
import { errorResult, FakeControlPlane } from "../../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import type { PendingSteer, SessionSteerParams } from "../../src/protocol/types.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal } from "../helpers/memory-terminal.ts";
import { waitFor } from "../helpers/wait.ts";

const teardown: Array<() => void> = [];
const key = "tui-steering";

beforeEach(() => initTheme({ colorLevel: 3 }));
afterEach(() => {
	while (teardown.length) teardown.pop()?.();
	resetTheme();
	invalidateThemeAdapters();
});

async function boot() {
	const server = await FakeControlPlane.start({
		methods: [
			"chat.send",
			"chat.history",
			"sessions.steer",
			"sessions.steer.withdraw",
			"sessions.steer.pending",
		],
	});
	teardown.push(() => server.stop());
	const pending = new Map<string, PendingSteer>();
	server.respondWith("chat.history", { messages: [] });
	server.onMethod("chat.send", (params: { sessionKey: string }) => ({
		runId: "routed-run",
		sessionKey: params.sessionKey,
	}));
	server.onMethod("sessions.steer", (params: SessionSteerParams) => {
		pending.set(params.messageId, {
			messageId: params.messageId,
			preview: params.prompt,
			acceptedAfterTurn: 2,
		});
		return { ...params, acceptedAfterTurn: 2 };
	});
	server.onMethod("sessions.steer.pending", (params: { sessionKey: string }) => ({
		sessionKey: params.sessionKey,
		items: params.sessionKey === key ? [...pending.values()] : [],
		truncated: false,
	}));
	server.onMethod(
		"sessions.steer.withdraw",
		(params: { sessionKey: string; messageId: string }) => {
			if (!pending.delete(params.messageId)) return errorResult("NOT_FOUND", "already bound");
			return { ...params, withdrawn: true };
		},
	);
	const client = new ControlPlaneClient({ url: server.url });
	const app = new AppShell({
		url: server.url,
		client,
		terminal: new MemoryTerminal(),
		sessionKey: key,
		readBranch: async () => "main",
	});
	teardown.push(() => app.stop());
	await app.start();
	await app.refreshSteers();
	app.events.noteRunStarted("run-live", app.store.focused);
	return { app, client, server, pending };
}

describe("journaled steering in the real shell", () => {
	test("uses the stable receipt id and removes the item only after withdrawal acknowledgement", async () => {
		const { app, server } = await boot();
		expect(await app.sendPrompt("correct direction", { mode: "steer" })).toBe("accepted");
		const item = app.store.queue.items(key)[0]!;
		const steer = server.requestsFor("sessions.steer")[0]!;
		expect(steer.params).toEqual({
			sessionKey: key,
			runId: "run-live",
			messageId: item.steer!.messageId,
			prompt: "correct direction",
		});
		expect(app.store.focused.activeRunId).toBe("run-live");
		expect(server.requestsFor("chat.send")).toHaveLength(0);
		app.editor.setText("keep this draft");
		app.editQueued(item);
		expect(app.editor.getExpandedText()).toBe("keep this draft");

		const ack = Promise.withResolvers<unknown>();
		server.onMethod("sessions.steer.withdraw", () => ack.promise);
		const withdrawal = app.deleteQueued(item);
		const request = await server.waitForRequest("sessions.steer.withdraw");
		expect(request.params).toEqual({ sessionKey: key, messageId: item.steer!.messageId });
		expect(app.store.queue.find(key, item.id)).toBeDefined();
		await app.deleteQueued(item);
		expect(server.requestsFor("sessions.steer.withdraw")).toHaveLength(1);
		app.store.setFocused("another-session");
		app.store.queue.push("another-session", "unrelated local prompt");
		ack.resolve({ sessionKey: key, messageId: item.steer!.messageId, withdrawn: true });
		await withdrawal;
		expect(app.store.queue.find(key, item.id)).toBeUndefined();
		expect(app.store.queue.items("another-session")[0]?.text).toBe("unrelated local prompt");
	});

	test.each(["NOT_FOUND", "UNAVAILABLE"])(
		"%s withdrawal keeps the last known item without replay",
		async (code) => {
			const { app, server } = await boot();
			await app.sendPrompt("correction", { mode: "steer" });
			const item = app.store.queue.items(key)[0]!;
			server.failWith("sessions.steer.withdraw", code, "not confirmed", { retrySafe: false });
			await app.deleteQueued(item);
			expect(app.store.queue.find(key, item.id)).toBeDefined();
			expect(server.requestsFor("sessions.steer.withdraw")).toHaveLength(1);
			expect(server.requestsFor("sessions.steer")).toHaveLength(1);
		},
	);

	test("offline withdrawal never hides the steer or queues a delayed mutation", async () => {
		const { app, client, server } = await boot();
		await app.sendPrompt("correction", { mode: "steer" });
		const item = app.store.queue.items(key)[0]!;
		client.close();
		await app.deleteQueued(item);
		expect(app.store.queue.find(key, item.id)).toBeDefined();
		expect(client.queued).toHaveLength(0);
		expect(server.requestsFor("sessions.steer.withdraw")).toHaveLength(0);
	});

	test("a stale pending read cannot resurrect an acknowledged withdrawal", async () => {
		const { app, server, pending } = await boot();
		await app.sendPrompt("correction", { mode: "steer" });
		const item = app.store.queue.items(key)[0]!;
		const stale = [...pending.values()];
		const started = Promise.withResolvers<void>();
		const reply = Promise.withResolvers<unknown>();
		server.onMethod("sessions.steer.pending", () => {
			started.resolve();
			return reply.promise;
		});
		const read = app.refreshSteers(key);
		await started.promise;
		await app.deleteQueued(item);
		reply.resolve({ sessionKey: key, items: stale, truncated: false });
		await read;
		expect(app.store.queue.items(key)).toEqual([]);
	});

	test("pending reads recover identities and only authoritative reads remove bound steers", async () => {
		const { app, server, pending } = await boot();
		pending.set("recovered", {
			messageId: "recovered",
			preview: "from before reconnect",
			acceptedAfterTurn: 1,
		});
		await app.refreshSteers(key);
		const item = app.store.queue.items(key)[0]!;
		expect(item.steer?.messageId).toBe("recovered");
		server.failWith("sessions.steer.pending", "UNAVAILABLE", "runtime unavailable");
		await app.refreshSteers(key);
		expect(app.store.queue.find(key, item.id)).toBeDefined();
		server.respondWith("sessions.steer.pending", { sessionKey: key, items: [], truncated: false });
		await app.refreshSteers(key);
		expect(app.store.queue.items(key)).toEqual([]);
	});

	test("unknown acceptance retains the fixed id for withdrawal and never falls back to another send", async () => {
		const { app, server } = await boot();
		server.onMethod("sessions.steer", (params: SessionSteerParams) => ({
			...params,
			messageId: "wrong",
		}));
		expect(await app.sendPrompt("uncertain correction", { mode: "steer" })).toBe("uncertain");
		const item = app.store.queue.items(key)[0]!;
		expect(item.state).toBe("needs-review");
		expect(item.steer?.messageId).toBe(
			(server.requestsFor("sessions.steer")[0]!.params as SessionSteerParams).messageId,
		);
		expect(await app.sendPrompt("do not replay", { mode: "steer" })).toBe("uncertain");
		expect(server.requestsFor("sessions.steer")).toHaveLength(1);
		expect(server.requestsFor("chat.send")).toHaveLength(0);
	});

	test("an uncertain steer the daemon does not hold can be dismissed after review", async () => {
		const { app, server } = await boot();
		server.silenceMethod("sessions.steer");
		const sending = app.sendPrompt("lost correction", { mode: "steer" });
		await waitFor(() => server.requestsFor("sessions.steer").length === 1);
		// The answer never arrives: the outcome of the steer is unknown.
		await app.client.reconnect("test");
		expect(await sending).toBe("uncertain");
		const item = app.store.queue.items(key)[0]!;
		expect(item.state).toBe("needs-review");
		expect(await app.sendPrompt("blocked", { mode: "steer" })).toBe("uncertain");

		// Edit stays refused (it could duplicate a pending steer); `d` checks with
		// the daemon, which reports it is not pending, and the review ends.
		app.editQueued(item);
		expect(app.store.queue.items(key)).toHaveLength(1);
		await app.deleteQueued(item);
		expect(server.requestsFor("sessions.steer.withdraw")).toHaveLength(1);
		expect(app.store.queue.items(key)).toEqual([]);

		server.onMethod("sessions.steer", (params: SessionSteerParams) => ({
			...params,
			acceptedAfterTurn: 3,
		}));
		expect(await app.sendPrompt("unblocked", { mode: "steer" })).toBe("accepted");
	});

	test("an uncertain steer that is still pending is withdrawn, not dismissed blindly", async () => {
		const { app, server, pending } = await boot();
		server.onMethod("sessions.steer", (params: SessionSteerParams) => {
			pending.set(params.messageId, {
				messageId: params.messageId,
				preview: params.prompt,
				acceptedAfterTurn: 2,
			});
			return errorResult("INTERNAL_ERROR", "Method execution failed");
		});
		expect(await app.sendPrompt("maybe journaled", { mode: "steer" })).toBe("uncertain");
		const item = app.store.queue.items(key)[0]!;
		await app.deleteQueued(item);
		expect(pending.size).toBe(0);
		expect(app.store.queue.items(key)).toEqual([]);
	});

	test("a stale run rejection is not silently rerouted or queued", async () => {
		const { app, server } = await boot();
		server.failWith("sessions.steer", "CONFLICT", "stale run");
		expect(await app.sendPrompt("stale correction", { mode: "steer" })).toBe("rejected");
		expect(app.store.queue.items(key)).toEqual([]);
		expect(server.requestsFor("chat.send")).toHaveLength(0);
	});
});
