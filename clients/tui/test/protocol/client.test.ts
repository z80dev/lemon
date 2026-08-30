import { afterEach, describe, expect, test } from "bun:test";
import { FakeControlPlane } from "../../src/dev/fake-server.ts";
import { acceptDeltaSeq, ControlPlaneClient } from "../../src/protocol/client.ts";
import {
	ControlPlaneError,
	HandshakeError,
	MethodUnavailableError,
	NotConnectedError,
	RequestTimeoutError,
} from "../../src/protocol/errors.ts";
import { ControlPlaneMethods } from "../../src/protocol/methods.ts";
import type { ChatDeltaEvent } from "../../src/protocol/types.ts";
import { AUTHENTICATED_CONNECT_PARAMS } from "./fixtures/control-plane-connect-contract.ts";

const teardown: Array<() => void> = [];

afterEach(() => {
	while (teardown.length > 0) teardown.pop()?.();
});

async function withServer(options?: ConstructorParameters<typeof FakeControlPlane>[0]) {
	const server = await FakeControlPlane.start(options);
	teardown.push(() => server.stop());
	return server;
}

function makeClient(url: string, overrides: Record<string, unknown> = {}) {
	const client = new ControlPlaneClient({
		url,
		requestTimeoutMs: 1500,
		socketOptions: { minBackoffMs: 10, maxBackoffMs: 40, jitter: 0, minWatchdogWindowMs: 0 },
		...overrides,
	});
	teardown.push(() => client.close());
	return client;
}

describe("handshake", () => {
	test("sends connect with operator role and no token, then goes online", async () => {
		const server = await withServer();
		const client = makeClient(server.url, { clientId: "lemon-tui@test-1" });

		const states: string[] = [];
		client.events.on("state", ({ state }) => states.push(state));

		const hello = await client.connect();

		expect(client.state).toBe("online");
		expect(hello.features.methods).toContain("chat.send");
		expect(client.serverMethods.has("health")).toBe(true);

		const connect = server.requestsFor("connect");
		expect(connect).toHaveLength(1);
		expect(connect[0].params).toEqual({ role: "operator", client: { id: "lemon-tui@test-1" } });
		expect(states).toContain("online");
	});

	test("sends the operator token in the auth envelope without logging it", async () => {
		const server = await withServer();
		const token = "control-plane-operator-secret";
		const client = makeClient(server.url, { token });

		await client.connect();

		const connect = server.requestsFor("connect");
		expect(connect).toHaveLength(1);
		expect(connect[0].params).toMatchObject({ auth: { token } });
		expect(client.recentFrames().join("\n")).not.toContain(token);
	});

	test("hello-ok event reports the first handshake as not resumed", async () => {
		const server = await withServer();
		const client = makeClient(server.url);
		const seen: boolean[] = [];
		client.events.on("hello-ok", ({ resumed }) => seen.push(resumed));
		await client.connect();
		expect(seen).toEqual([false]);
	});

	test("sends authenticated connect params using the server contract envelope", async () => {
		const server = await withServer();
		const client = makeClient(server.url, {
			clientId: AUTHENTICATED_CONNECT_PARAMS.client.id,
			token: AUTHENTICATED_CONNECT_PARAMS.auth.token,
		});

		await client.connect();

		const connect = server.requestsFor("connect");
		expect(connect).toHaveLength(1);
		expect(connect[0].params).toEqual(AUTHENTICATED_CONNECT_PARAMS);
		expect(connect[0].params).not.toHaveProperty("token");
	});

	test("an auth rejection rejects connect()", async () => {
		const server = await withServer({
			rejectHandshake: { code: "UNAUTHORIZED", message: "bad token" },
		});
		const client = makeClient(server.url);
		await expect(client.connect()).rejects.toBeInstanceOf(HandshakeError);
	});
});

describe("request correlation", () => {
	test("resolves the matching response payload", async () => {
		const server = await withServer();
		server.respondWith("health", { ok: true, uptimeMs: 42 });
		const client = makeClient(server.url);
		await client.connect();

		const payload = await client.request<Record<string, unknown>>("health");
		expect(payload).toEqual({ ok: true, uptimeMs: 42 });
	});

	test("concurrent requests resolve independently and out of order", async () => {
		const server = await withServer();
		server.onMethod("status", async () => {
			await Bun.sleep(40);
			return { which: "status" };
		});
		server.respondWith("health", { which: "health" });
		const client = makeClient(server.url);
		await client.connect();

		const [status, health] = await Promise.all([
			client.request<{ which: string }>("status"),
			client.request<{ which: string }>("health"),
		]);
		expect(status.which).toBe("status");
		expect(health.which).toBe("health");
	});

	test("ok:false becomes a typed ControlPlaneError", async () => {
		const server = await withServer();
		server.failWith("session.detail", "NOT_FOUND", "Session not found", { sessionKey: "nope" });
		const client = makeClient(server.url);
		await client.connect();

		const error: any = await client
			.request("session.detail", { sessionKey: "nope" })
			.catch((e: any) => e);
		expect(error).toBeInstanceOf(ControlPlaneError);
		expect(error.code).toBe("NOT_FOUND");
		expect(error.message).toBe("Session not found");
		expect(error.details).toEqual({ sessionKey: "nope" });
		expect(error.method).toBe("session.detail");
	});

	test("an unanswered request times out", async () => {
		const server = await withServer();
		server.silenceMethod("status");
		const client = makeClient(server.url);
		await client.connect();

		const error: any = await client
			.request("status", undefined, { timeoutMs: 60 })
			.catch((e: any) => e);
		expect(error).toBeInstanceOf(RequestTimeoutError);
		expect(error.method).toBe("status");
	});

	test("non-queueable methods reject while offline", async () => {
		const client = makeClient("ws://127.0.0.1:1/ws");
		const error: any = await client.request("health").catch((e: any) => e);
		expect(error).toBeInstanceOf(NotConnectedError);
	});
});

describe("session lifecycle offline safety", () => {
	test("metadata, prune, delete, and export never enter the reconnect queue", async () => {
		const client = makeClient("ws://127.0.0.1:1/ws");
		const methods = new ControlPlaneMethods(client);
		for (const request of [
			methods.sessionsMetadataPatch({ sessionKey: "s1", pinned: true }),
			methods.sessionsPrune({ olderThanMs: 1, dryRun: false, confirmToken: "token" }),
			methods.sessionsDelete({ sessionKey: "s1" }),
			methods.sessionsExport({ sessionKey: "s1", format: "json" }),
		]) {
			await expect(request).rejects.toBeInstanceOf(NotConnectedError);
		}
		expect(client.queued).toHaveLength(0);
	});
});

describe("blueprint activation offline safety", () => {
	test("activation never enters the reconnect queue", async () => {
		const client = makeClient("ws://127.0.0.1:1/ws");
		const methods = new ControlPlaneMethods(client);
		await expect(
			methods.blueprintsActivate({
				bundleId: "daily-note",
				profileId: "operator",
				confirmationDigest: "a".repeat(64),
			}),
		).rejects.toBeInstanceOf(NotConnectedError);
		expect(client.queued).toHaveLength(0);
	});
});

describe("events", () => {
	test("demuxes server events to typed listeners", async () => {
		const server = await withServer();
		const client = makeClient(server.url);
		await client.connect();

		const deltas: ChatDeltaEvent[] = [];
		client.events.on("chat", (event) => deltas.push(event as ChatDeltaEvent));
		const agentEvents: unknown[] = [];
		client.events.on("agent", (event) => agentEvents.push(event));

		server.pushEvent("chat", { type: "delta", runId: "r1", sessionKey: "s1", seq: 1, text: "he" });
		server.pushEvent("chat", { type: "delta", runId: "r1", sessionKey: "s1", seq: 2, text: "llo" });
		server.pushEvent("agent", { type: "completed", runId: "r1", sessionKey: "s1", ok: true });

		await Bun.sleep(30);
		expect(deltas.map((d) => d.text)).toEqual(["he", "llo"]);
		expect(agentEvents).toHaveLength(1);
	});

	test("unknown events land on the unknown-event channel", async () => {
		const server = await withServer();
		const client = makeClient(server.url);
		await client.connect();

		const unknown: string[] = [];
		client.events.on("unknown-event", (frame) => unknown.push(frame.event));
		server.pushEvent("some.future.event", { hello: true });
		await Bun.sleep(20);
		expect(unknown).toEqual(["some.future.event"]);
	});

	test("a malformed frame is reported without killing the connection", async () => {
		const server = await withServer();
		server.respondWith("health", { ok: true });
		const client = makeClient(server.url);
		await client.connect();

		const errors: string[] = [];
		client.events.on("client-error", ({ context }) => errors.push(context));
		server.broadcast("this is not json");
		await Bun.sleep(20);

		expect(errors).toContain("decode");
		expect(await client.request<Record<string, unknown>>("health")).toEqual({ ok: true });
	});

	test("acceptDeltaSeq drops replayed and out-of-order deltas", () => {
		const seen = new Map<string, number>();
		expect(acceptDeltaSeq(seen, "r1", 1)).toBe(true);
		expect(acceptDeltaSeq(seen, "r1", 2)).toBe(true);
		expect(acceptDeltaSeq(seen, "r1", 2)).toBe(false);
		expect(acceptDeltaSeq(seen, "r1", 1)).toBe(false);
		expect(acceptDeltaSeq(seen, "r2", 1)).toBe(true);
		expect(acceptDeltaSeq(seen, "r1", 3)).toBe(true);
	});
});

describe("reconnect", () => {
	test("re-handshakes and flushes the offline chat.send queue", async () => {
		const server = await withServer();
		server.onMethod("chat.send", (params: { sessionKey: string; prompt: string }) => ({
			runId: `run-${params.prompt}`,
			sessionKey: params.sessionKey,
		}));
		// A deliberately slow reconnect leaves a window to type into.
		const client = makeClient(server.url, {
			socketOptions: { minBackoffMs: 250, maxBackoffMs: 250, jitter: 0 },
		});
		await client.connect();

		const resyncs: number[] = [];
		client.events.on("resync-needed", () => resyncs.push(1));
		const queued: string[] = [];
		client.events.on("queued", ({ method }) => queued.push(method));

		server.dropConnections();
		await Bun.sleep(20);
		expect(client.state).not.toBe("online");

		// Typed while the daemon is unreachable: held, not rejected.
		const first = client.request<{ runId: string }>("chat.send", { sessionKey: "s1", prompt: "a" });
		const second = client.request<{ runId: string }>("chat.send", {
			sessionKey: "s1",
			prompt: "b",
		});
		expect(client.queued).toHaveLength(2);
		expect(queued).toEqual(["chat.send", "chat.send"]);

		expect((await first).runId).toBe("run-a");
		expect((await second).runId).toBe("run-b");

		// FIFO order preserved across the reconnect.
		const sends = server.requestsFor("chat.send");
		expect(sends.map((frame) => (frame.params as { prompt: string }).prompt)).toEqual(["a", "b"]);
		expect(client.state).toBe("online");
		expect(resyncs).toHaveLength(1);
		expect(server.requestsFor("connect")).toHaveLength(2);
	});

	test("in-flight requests reject when the connection drops", async () => {
		const server = await withServer();
		server.silenceMethod("status");
		const client = makeClient(server.url);
		await client.connect();

		const pending = client.request("status").catch((e: any) => e);
		await Bun.sleep(10);
		server.dropConnections();

		const error: any = await pending;
		expect(error).toBeInstanceOf(NotConnectedError);
	});
});

describe("method gating", () => {
	test("wrappers reject methods the daemon does not advertise", async () => {
		const server = await withServer({ methods: ["chat.send", "health"] });
		const client = makeClient(server.url);
		const methods = new ControlPlaneMethods(client);
		await client.connect();

		expect(methods.supports("chat.send")).toBe(true);
		expect(methods.supports("models.list")).toBe(false);
		const error: any = await methods.modelsList().catch((e: any) => e);
		expect(error).toBeInstanceOf(MethodUnavailableError);
		expect(error.method).toBe("models.list");
		expect(server.requestsFor("models.list")).toHaveLength(0);
	});

	test("the gate is open before the handshake so chat.send can be queued", async () => {
		const client = makeClient("ws://127.0.0.1:1/ws");
		const methods = new ControlPlaneMethods(client);
		expect(methods.supports("models.list")).toBe(true);
		// Not awaited: it stays parked in the offline queue.
		void methods.chatSend({ sessionKey: "s1", prompt: "hi" }).catch(() => {});
		await Bun.sleep(5);
		expect(client.queued.map((entry) => entry.method)).toEqual(["chat.send"]);
	});

	test("profile.chat can be queued offline without losing its canonical route", async () => {
		const client = makeClient("ws://127.0.0.1:1/ws");
		const methods = new ControlPlaneMethods(client);
		void methods
			.profileChat({ id: "research", prompt: "keep going", queueMode: "steer" })
			.catch(() => {});
		await Bun.sleep(5);

		expect(client.queued).toHaveLength(1);
		expect(client.queued[0]).toMatchObject({
			method: "profile.chat",
			params: { id: "research", prompt: "keep going", queueMode: "steer" },
		});
	});

	test("chatHistory defaults includeFullText to true", async () => {
		const server = await withServer();
		server.respondWith("chat.history", { sessionKey: "s1", messages: [] });
		const client = makeClient(server.url);
		const methods = new ControlPlaneMethods(client);
		await client.connect();

		await methods.chatHistory({ sessionKey: "s1", limit: 10 });
		const frame = server.requestsFor("chat.history")[0];
		expect(frame.params).toEqual({ includeFullText: true, sessionKey: "s1", limit: 10 });
	});
});

describe("liveness", () => {
	test("a quiet but healthy connection is probed, not dropped", async () => {
		// tickIntervalMs 20 -> a 60ms silence window, and the fake server sends
		// nothing on its own, exactly like an idle daemon.
		const server = await withServer({ tickIntervalMs: 20 });
		let healthCalls = 0;
		server.onMethod("health", () => {
			healthCalls += 1;
			return { ok: true };
		});
		const client = makeClient(server.url);
		await client.connect();

		await Bun.sleep(250);
		expect(healthCalls).toBeGreaterThanOrEqual(1);
		expect(client.state).toBe("online");
		expect(server.requestsFor("connect")).toHaveLength(1);
	});

	test("an unanswered probe forces a reconnect", async () => {
		const server = await withServer({ tickIntervalMs: 20 });
		server.silenceMethod("health");
		server.silenceMethod("status");
		const client = makeClient(server.url, { requestTimeoutMs: 60 });
		await client.connect();

		await Bun.sleep(400);
		expect(server.requestsFor("connect").length).toBeGreaterThanOrEqual(2);
	});
});
