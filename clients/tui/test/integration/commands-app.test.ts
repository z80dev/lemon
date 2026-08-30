/**
 * P5 through the real shell: keys and slash commands driven at the terminal,
 * asserted on what the frame says.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import { AppShell } from "../../src/app.ts";
import { FakeControlPlane } from "../../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal, renderPlain, stripAnsi } from "../helpers/memory-terminal.ts";
import { waitFor } from "../helpers/wait.ts";

const CTRL_O = "\x0f";

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
	server.respondWith("sessions.patch", { success: true });
	server.respondWith("models.list", {
		models: [
			{ id: "claude-sonnet-4", provider: "anthropic", contextWindow: 200_000 },
			{ id: "gpt-4o", provider: "openai", contextWindow: 128_000 },
		],
	});
	server.respondWith("usage.status", {
		period: "today",
		tokens: { input: 40_000, output: 8_000 },
		summary: { totalTokens: 48_000 },
	});
	server.respondWith("status", { server: { version: "fake-0.0.0" }, runs: { active: 0 } });

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
		cwd: process.cwd(),
		onExit: (code) => exits.push(code),
		// Deterministic branch: the real poll would depend on the checkout.
		readBranch: async () => "main",
	});
	teardown.push(() => app.stop());
	await app.start();
	return { app, server, terminal, exits };
}

function chatText(app: AppShell): string {
	return renderPlain(app.chatContainer.render(80));
}

describe("slash commands in the app", () => {
	test("/help renders the registry into the transcript", async () => {
		const { app } = await bootApp();
		await app.submit("/help");
		const text = chatText(app);
		expect(text).toContain("/status");
		expect(text).toContain("/model");
	});

	test("/status renders a card and sends no prompt", async () => {
		const { app, server } = await bootApp();
		await app.submit("/status");
		expect(chatText(app)).toContain("fake-0.0.0");
		expect(server.requestsFor("chat.send")).toHaveLength(0);
	});

	test("/model applies to the session and shows in the status bar", async () => {
		const { app, server } = await bootApp();
		await app.submit("/model gpt-4o");
		expect(server.requestsFor("sessions.patch")[0].params).toMatchObject({ model: "gpt-4o" });
		expect(stripAnsi(app.statusBar.render(120)[0])).toContain("gpt-4o");
	});

	test("/clear empties the transcript", async () => {
		const { app } = await bootApp();
		await app.submit("hello");
		expect(chatText(app)).toContain("hello");
		await app.submit("/clear");
		expect(chatText(app)).not.toContain("hello");
	});

	test("an unknown command stays local", async () => {
		const { app, server } = await bootApp();
		await app.submit("/nonsense");
		expect(chatText(app)).toContain("unknown command");
		expect(server.requestsFor("chat.send")).toHaveLength(0);
	});

	test("/bg carries app context and supports result retrieval end to end", async () => {
		const { app, server } = await bootApp("durable-tui-session");
		const id = "019d-full-background-id-0123456789abcdefghijklmnopqrstuvwxyz";
		server.respondWith("background.start", { id, status: "queued" });
		server.respondWith("background.result", {
			id,
			ready: true,
			answer: "Background work finished.",
		});

		await app.submit("/model gpt-4o");
		await app.submit("/reasoning high");
		await app.submit("/bg inspect the workspace");
		await app.submit(`/bg result ${id}`);

		expect(server.requestsFor("background.start")[0].params).toEqual({
			prompt: "inspect the workspace",
			sessionKey: "durable-tui-session",
			cwd: process.cwd(),
			model: "gpt-4o",
			thinkingLevel: "high",
		});
		expect(chatText(app)).toContain(id);
		expect(chatText(app)).toContain("Background work finished.");
	});
});

describe("the status bar", () => {
	test("is mounted, single-line, and fits every width", async () => {
		const { app } = await bootApp();
		for (const width of [60, 80, 100, 120]) {
			const rows = app.statusLineContainer.render(width);
			expect(rows).toHaveLength(1);
			expect(visibleWidth(rows[0])).toBeLessThanOrEqual(width);
		}
	});

	test("labels today's aggregate usage as usage, not as context", async () => {
		const { app } = await bootApp();
		await app.refreshUsage();
		await app.submit("/model claude-sonnet-4");
		const line = stripAnsi(app.statusBar.render(120)[0]);
		// `usage.status` totals every session's whole day. Drawing that against one
		// model's window would read as "this conversation is 24% full", which it is not.
		expect(line).toContain("use 48k");
		expect(line).not.toContain("48k/200k");
		expect(line).not.toContain("24%");
	});

	test("draws the gauge from a run's own usage", async () => {
		const { app, server } = await bootApp();
		await app.submit("/model claude-sonnet-4");
		server.pushEvent("agent", {
			type: "completed",
			runId: "run-1",
			sessionKey: "tui-test",
			ok: true,
			answer: "done",
			durationMs: 10,
			model: "claude-sonnet-4",
			usage: { inputTokens: 40_000, outputTokens: 500, cacheReadTokens: 8_000 },
		});
		await waitFor(() => stripAnsi(app.statusBar.render(120)[0]).includes("48k/200k"), {
			what: "the context gauge",
		});
		expect(stripAnsi(app.statusBar.render(120)[0])).toContain("24%");
	});

	test("names the model a run reported, over the one set locally", async () => {
		const { app, server } = await bootApp();
		await app.submit("/model gpt-4o");
		expect(stripAnsi(app.statusBar.render(120)[0])).toContain("gpt-4o");

		server.pushEvent("agent", {
			type: "started",
			runId: "run-2",
			sessionKey: "tui-test",
			engine: "coding_agent",
			model: "claude-sonnet-4",
			provider: "anthropic",
		});
		await waitFor(() => stripAnsi(app.statusBar.render(120)[0]).includes("claude-sonnet-4"), {
			what: "the model the run reported",
		});
	});

	test("shows the branch the poll reported", async () => {
		const { app } = await bootApp();
		await waitFor(() => stripAnsi(app.statusBar.render(120)[0]).includes("main"), {
			what: "the git branch",
		});
	});
});

describe("global keys", () => {
	test("Ctrl+O opens the model picker as an overlay", async () => {
		const { app, terminal } = await bootApp();
		terminal.sendInput(CTRL_O);
		await waitFor(() => app.selectors.isOpen, { what: "the model picker" });
		expect(app.tui.hasOverlay()).toBe(true);
		// Esc closes it and the editor gets focus back.
		app.selectors.current?.handleInput?.("\x1b");
		await waitFor(() => !app.selectors.isOpen, { what: "the picker to close" });
		expect(app.tui.getFocused()).toBe(app.editor);
	});

	test("a picker leaves the draft untouched", async () => {
		const { app, terminal } = await bootApp();
		app.editor.handleInput("half a prompt");
		terminal.sendInput(CTRL_O);
		await waitFor(() => app.selectors.isOpen, { what: "the model picker" });
		app.selectors.current?.handleInput?.("\x1b");
		expect(app.editor.getText()).toBe("half a prompt");
	});
});

describe("shell escapes", () => {
	test("!cmd is recorded in the transcript and nothing is sent", async () => {
		const { app, server } = await bootApp();
		// The command owns the real terminal, so its output is not ours to
		// capture — the transcript records that it ran and how it ended.
		await app.submit("!true");
		expect(chatText(app)).toContain("$ true");
		expect(chatText(app)).toContain("ok");
		expect(server.requestsFor("chat.send")).toHaveLength(0);
	});

	test("{!cmd} is interpolated into the prompt that is sent", async () => {
		const { app, server } = await bootApp();
		await app.submit("the answer is {!echo 42}");
		await waitFor(() => server.requestsFor("chat.send").length > 0, { what: "chat.send" });
		expect(server.requestsFor("chat.send")[0].params).toMatchObject({
			prompt: "the answer is 42",
		});
	});
});
