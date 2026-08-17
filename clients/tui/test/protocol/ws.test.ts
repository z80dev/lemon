import { afterEach, describe, expect, test } from "bun:test";
import { FakeControlPlane } from "../../src/dev/fake-server.ts";
import { computeBackoffDelay, MIN_WATCHDOG_WINDOW_MS, ReconnectingSocket } from "../../src/protocol/ws.ts";

const teardown: Array<() => void> = [];

afterEach(() => {
	while (teardown.length > 0) teardown.pop()?.();
});

describe("computeBackoffDelay", () => {
	test("doubles from the floor up to the ceiling", () => {
		const options = { minBackoffMs: 500, maxBackoffMs: 15_000, jitter: 0 };
		const noJitter = () => 0.5;
		expect(computeBackoffDelay(1, options, noJitter)).toBe(500);
		expect(computeBackoffDelay(2, options, noJitter)).toBe(1000);
		expect(computeBackoffDelay(3, options, noJitter)).toBe(2000);
		expect(computeBackoffDelay(6, options, noJitter)).toBe(15_000);
		expect(computeBackoffDelay(20, options, noJitter)).toBe(15_000);
	});

	test("jitter stays inside the band and never exceeds the ceiling", () => {
		const options = { minBackoffMs: 500, maxBackoffMs: 15_000, jitter: 0.25 };
		expect(computeBackoffDelay(2, options, () => 0)).toBe(750); // 1000 * 0.75
		expect(computeBackoffDelay(2, options, () => 1)).toBe(1250); // 1000 * 1.25
		expect(computeBackoffDelay(30, options, () => 1)).toBe(15_000);
	});
});

describe("ReconnectingSocket", () => {
	test("reconnects after the server drops the connection", async () => {
		const server = await FakeControlPlane.start();
		teardown.push(() => server.stop());
		const socket = new ReconnectingSocket({
			url: server.url,
			minBackoffMs: 10,
			maxBackoffMs: 20,
			jitter: 0,
		});
		teardown.push(() => socket.close());

		const opens: boolean[] = [];
		socket.events.on("open", ({ reconnected }) => opens.push(reconnected));
		socket.connect();
		await server.waitForConnection();
		await Bun.sleep(10);

		server.dropConnections();
		await Bun.sleep(120);

		expect(opens.length).toBeGreaterThanOrEqual(2);
		expect(opens[0]).toBe(false);
		expect(opens[1]).toBe(true);
		expect(socket.isOpen).toBe(true);
	});

	test("close() is permanent — no reconnect is scheduled", async () => {
		const server = await FakeControlPlane.start();
		teardown.push(() => server.stop());
		const socket = new ReconnectingSocket({ url: server.url, minBackoffMs: 10, jitter: 0 });

		let opens = 0;
		socket.events.on("open", () => {
			opens += 1;
		});
		socket.connect();
		await server.waitForConnection();
		await Bun.sleep(10);
		socket.close();
		await Bun.sleep(80);

		expect(opens).toBe(1);
		expect(socket.state).toBe("closed");
	});

	test("the liveness watchdog forces a reconnect on a silent connection", async () => {
		const server = await FakeControlPlane.start();
		teardown.push(() => server.stop());
		const socket = new ReconnectingSocket({
			url: server.url,
			minBackoffMs: 10,
			maxBackoffMs: 20,
			jitter: 0,
			watchdogMultiplier: 3,
			minWatchdogWindowMs: 0,
		});
		teardown.push(() => socket.close());

		const stale: number[] = [];
		socket.events.on("stale", (info) => stale.push(info.windowMs));
		let opens = 0;
		socket.events.on("open", () => {
			opens += 1;
		});

		socket.connect();
		await server.waitForConnection();
		await Bun.sleep(10);

		// Armed only once the server's policy supplies a tick interval.
		expect(socket.livenessWindowMs).toBeUndefined();
		socket.setTickIntervalMs(20);
		expect(socket.livenessWindowMs).toBe(60);

		await Bun.sleep(150);
		// Silence reports, repeatedly, but does not itself drop the connection:
		// an idle daemon sends no frames, and the owner probes before giving up.
		expect(stale[0]).toBe(60);
		expect(stale.length).toBeGreaterThanOrEqual(2);
		expect(socket.isOpen).toBe(true);
		expect(opens).toBe(1);

		socket.forceReconnect("test");
		await Bun.sleep(80);
		expect(opens).toBeGreaterThanOrEqual(2);
	});

	test("traffic keeps the watchdog from firing", async () => {
		const server = await FakeControlPlane.start();
		teardown.push(() => server.stop());
		const socket = new ReconnectingSocket({
			url: server.url,
			minBackoffMs: 10,
			jitter: 0,
			minWatchdogWindowMs: 0,
		});
		teardown.push(() => socket.close());

		const stale: unknown[] = [];
		socket.events.on("stale", (info) => stale.push(info));
		socket.connect();
		await server.waitForConnection();
		socket.setTickIntervalMs(30); // 90ms window

		for (let i = 0; i < 6; i++) {
			server.pushEvent("tick", { timestampMs: Date.now() });
			await Bun.sleep(30);
		}
		expect(stale).toHaveLength(0);
		expect(socket.isOpen).toBe(true);
	});

	test("frames are delivered as raw text", async () => {
		const server = await FakeControlPlane.start();
		teardown.push(() => server.stop());
		const socket = new ReconnectingSocket({ url: server.url });
		teardown.push(() => socket.close());

		const frames: string[] = [];
		socket.events.on("frame", (frame) => frames.push(frame));
		socket.connect();
		await server.waitForConnection();
		await Bun.sleep(10);
		server.pushEvent("tick", { timestampMs: 1 });
		await Bun.sleep(20);

		expect(frames).toHaveLength(1);
		expect(JSON.parse(frames[0])).toMatchObject({ type: "event", event: "tick" });
	});

	test("send() reports failure while the socket is down", () => {
		const socket = new ReconnectingSocket({ url: "ws://127.0.0.1:1/ws" });
		teardown.push(() => socket.close());
		expect(socket.send("{}")).toBe(false);
	});

	test("the liveness window never drops below the default floor", () => {
		const socket = new ReconnectingSocket({ url: "ws://127.0.0.1:1/ws" });
		teardown.push(() => socket.close());
		socket.setTickIntervalMs(1000);
		expect(socket.livenessWindowMs).toBe(MIN_WATCHDOG_WINDOW_MS);
		socket.setTickIntervalMs(60_000);
		expect(socket.livenessWindowMs).toBe(180_000);
	});
});
