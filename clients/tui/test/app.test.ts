import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import { AppShell, defaultSessionKey } from "../src/app.ts";
import { FakeControlPlane } from "../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../src/protocol/client.ts";
import { initTheme, resetTheme } from "../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal, renderPlain } from "./helpers/memory-terminal.ts";
import { waitForText } from "./helpers/wait.ts";

const teardown: Array<() => void> = [];

beforeEach(() => {
	initTheme({ colorLevel: 3 });
});

afterEach(() => {
	while (teardown.length > 0) teardown.pop()?.();
	resetTheme();
	invalidateThemeAdapters();
});

async function bootApp(sessionKey = "tui-test") {
	const server = await FakeControlPlane.start();
	teardown.push(() => server.stop());
	server.onMethod("chat.send", (params: { sessionKey: string }) => ({
		runId: "run-1",
		sessionKey: params.sessionKey,
	}));
	server.respondWith("chat.abort", { aborted: true, runId: "run-1" });

	const terminal = new MemoryTerminal();
	const client = new ControlPlaneClient({
		url: server.url,
		socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
	});
	const exits: number[] = [];
	const app = new AppShell({
		url: server.url,
		sessionKey,
		version: "test",
		client,
		terminal,
		onExit: (code) => exits.push(code),
	});
	teardown.push(() => app.stop());
	await app.start();
	return { app, server, terminal, exits };
}

function chatText(app: AppShell): string {
	return renderPlain(app.chatContainer.render(80));
}

describe("AppShell", () => {
	test("submitting a prompt sends chat.send for the active session", async () => {
		const { app, server } = await bootApp("tui-session-a");
		await app.submit("what is the status?");

		const frame = server.requestsFor("chat.send")[0];
		expect(frame.params).toEqual({ sessionKey: "tui-session-a", prompt: "what is the status?" });
		expect(chatText(app)).toContain("what is the status?");
	});

	test("blank submissions are ignored", async () => {
		const { app, server } = await bootApp();
		await app.submit("   \n  ");
		expect(server.requestsFor("chat.send")).toHaveLength(0);
	});

	test("streams deltas into one block and finalizes on completed", async () => {
		const { app, server } = await bootApp();
		await app.submit("hi");

		server.pushEvent("agent", { type: "started", runId: "run-1", sessionKey: "tui-test" });
		server.pushEvent("chat", {
			type: "delta",
			runId: "run-1",
			sessionKey: "tui-test",
			seq: 1,
			text: "Hello ",
		});
		server.pushEvent("chat", {
			type: "delta",
			runId: "run-1",
			sessionKey: "tui-test",
			seq: 2,
			text: "world",
		});
		// Replayed delta: must not duplicate text.
		server.pushEvent("chat", {
			type: "delta",
			runId: "run-1",
			sessionKey: "tui-test",
			seq: 2,
			text: "world",
		});
		// The reveal lands the text over a few 30fps frames.
		await waitForText(() => chatText(app), "Hello world");

		server.pushEvent("agent", {
			type: "completed",
			runId: "run-1",
			sessionKey: "tui-test",
			ok: true,
			// Server-truncated answer must lose to the accumulated buffer.
			answer: "Hello wo",
			durationMs: 10,
		});
		await Bun.sleep(30);
		const text = chatText(app);
		expect(text).toContain("Hello world");
		expect(text.split("Hello world")).toHaveLength(2);
	});

	test("events for other sessions are ignored", async () => {
		const { app, server } = await bootApp("tui-mine");
		server.pushEvent("chat", {
			type: "delta",
			runId: "other-run",
			sessionKey: "someone-else",
			seq: 1,
			text: "not mine",
		});
		await Bun.sleep(30);
		expect(chatText(app)).not.toContain("not mine");
	});

	test("Ctrl+C aborts an active run, then a double press exits", async () => {
		const { app, server, terminal, exits } = await bootApp();
		await app.submit("hi");
		server.pushEvent("agent", { type: "started", runId: "run-1", sessionKey: "tui-test" });
		await Bun.sleep(20);

		terminal.sendInput("\x03");
		await Bun.sleep(20);
		expect(server.requestsFor("chat.abort")).toHaveLength(1);
		expect(exits).toHaveLength(0);

		server.pushEvent("agent", {
			type: "completed",
			runId: "run-1",
			sessionKey: "tui-test",
			ok: true,
			answer: "",
		});
		await Bun.sleep(20);

		terminal.sendInput("\x03");
		expect(exits).toHaveLength(0);
		expect(chatText(app)).toContain("press Ctrl+C again to quit");
		terminal.sendInput("\x03");
		expect(exits).toEqual([0]);
	});

	test("Ctrl+D exits immediately", async () => {
		const { terminal, exits } = await bootApp();
		terminal.sendInput("\x04");
		expect(exits).toEqual([0]);
	});

	test("every rendered line fits the requested width", async () => {
		const { app, server } = await bootApp();
		await app.submit("a fairly long prompt that has to wrap somewhere around here for sure");
		server.pushEvent("chat", {
			type: "delta",
			runId: "run-1",
			sessionKey: "tui-test",
			seq: 1,
			text: "# Heading\n\nsome **bold** words and a longer paragraph that must wrap cleanly.",
		});
		await Bun.sleep(40);

		for (const width of [40, 60, 80, 120]) {
			for (const line of app.chatContainer.render(width)) {
				expect(visibleWidth(line)).toBeLessThanOrEqual(width);
			}
		}
	});

	test("chrome rows fit even a very narrow terminal", async () => {
		const { app } = await bootApp();
		// pi-tui keeps a Text's padding at every width, so the banner, connection
		// and status lines must clamp their own rows.
		for (const width of [1, 2, 3, 4, 6, 10]) {
			for (const container of [app.bannerContainer, app.statusLineContainer]) {
				for (const line of container.render(width)) {
					expect(visibleWidth(line)).toBeLessThanOrEqual(width);
				}
			}
		}
	});

	test("defaultSessionKey is stable and timestamped", () => {
		const key = defaultSessionKey(new Date("2026-08-16T12:34:56.000Z"));
		expect(key).toBe("tui-20260816T123456");
	});
});
