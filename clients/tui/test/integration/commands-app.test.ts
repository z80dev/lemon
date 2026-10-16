/**
 * P5 through the real shell: keys and slash commands driven at the terminal,
 * asserted on what the frame says.
 */

import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import { AppShell } from "../../src/app.ts";
import { PromptHistoryStore } from "../../src/composer/prompt-history.ts";
import { FakeControlPlane } from "../../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal, renderPlain, stripAnsi } from "../helpers/memory-terminal.ts";
import { waitFor } from "../helpers/wait.ts";

const CTRL_O = "\x0f";
const CTRL_P = "\x10";

const teardown: Array<() => void> = [];

beforeEach(() => {
	initTheme({ colorLevel: 3 });
});

afterEach(() => {
	while (teardown.length > 0) teardown.pop()?.();
	resetTheme();
	invalidateThemeAdapters();
});

async function bootApp(
	sessionKey = "tui-test",
	cwd = process.cwd(),
	promptHistory?: PromptHistoryStore,
) {
	// Local discovery (file commands, palette) must never read the real home.
	const home = mkdtempSync(join(tmpdir(), "lemon-tui-home-"));
	teardown.push(() => rmSync(home, { recursive: true, force: true }));
	// Match the advertised protocol to this fixture's implemented services.
	// Unrelated activity/routing/approval hydration must not participate in boot.
	const server = await FakeControlPlane.start({
		methods: [
			"chat.send",
			"chat.abort",
			"chat.history",
			"sessions.patch",
			"sessions.reset",
			"models.list",
			"usage.status",
			"status",
			"health",
			"background.start",
			"background.result",
		],
	});
	teardown.push(() => server.stop());
	server.onMethod("chat.send", (params: { sessionKey: string }) => ({
		runId: "run-1",
		sessionKey: params.sessionKey,
	}));
	server.respondWith("chat.abort", { aborted: true, runId: "run-1" });
	server.respondWith("chat.history", { messages: [] });
	server.respondWith("health", { status: "ok" });
	server.respondWith("sessions.reset", { success: true });
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
		cwd,
		promptHistory,
		resources: { home, env: {} },
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

async function bootDisconnectedApp(url: string) {
	const home = mkdtempSync(join(tmpdir(), "lemon-tui-disconnected-"));
	teardown.push(() => rmSync(home, { recursive: true, force: true }));
	const terminal = new MemoryTerminal();
	const client = new ControlPlaneClient({ url, requestTimeoutMs: 25 });
	const app = new AppShell({
		url,
		client,
		terminal,
		resources: { home, env: {} },
		readBranch: async () => null,
	});
	teardown.push(() => app.stop());
	await app.start();
	return { app, terminal };
}

describe("connection failure recovery", () => {
	test("a rejected token leaves connecting, keeps the draft, and sends nothing", async () => {
		const server = await FakeControlPlane.start({
			rejectHandshake: { code: "UNAUTHORIZED", message: "Operator token is invalid" },
		});
		teardown.push(() => server.stop());
		const { app, terminal } = await bootDisconnectedApp(server.url);
		expect(app.client.state).toBe("auth-rejected");
		expect(stripAnsi(app.statusBar.render(160)[0])).toContain("auth rejected");
		terminal.sendInput("keep this prompt");
		terminal.sendInput("\r");
		await waitFor(() => app.editor.getExpandedText() === "keep this prompt", {
			what: "the refused editor draft",
		});
		expect(app.editor.getExpandedText()).toBe("keep this prompt");
		expect(app.client.queued).toHaveLength(0);
		expect(server.requestsFor("chat.send")).toHaveLength(0);
		expect(chatText(app)).toContain("LEMON_CONTROL_PLANE_OPERATOR_TOKEN");
		expect(chatText(app).replace(/\s+/g, " ")).toContain("nothing queued or sent");
		await app.submit("/reconnect");
		expect(chatText(app)).toContain("reconnect failed: auth rejected");
	});

	test("an unreachable runtime explains startup and retains text without queueing", async () => {
		const server = await FakeControlPlane.start();
		const url = server.url;
		server.stop();
		// Exercise the real socket/deadline boundary; no arbitrary wait is needed.
		const { app } = await bootDisconnectedApp(url);
		expect(chatText(app)).toContain(`Lemon isn't running at ${url}`);
		expect(chatText(app)).toContain("lemon start");
		expect(chatText(app)).toContain("/reconnect");
		expect(chatText(app)).not.toContain("handshake");
		app.editor.setText("do not send this later");
		expect(await app.submit("do not send this later")).toBe("rejected");
		expect(app.editor.getExpandedText()).toBe("do not send this later");
		expect(app.client.queued).toHaveLength(0);
		await app.submit("/reconnect");
		expect(chatText(app)).toContain("reconnect failed:");
	});
});

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
		expect(server.requestsFor("sessions.patch")[0].params).toMatchObject({
			model: "openai:gpt-4o",
		});
		expect(stripAnsi(app.statusBar.render(120)[0])).toContain("gpt-4o");
	});

	test("/clear empties the transcript", async () => {
		const { app } = await bootApp();
		await app.submit("hello");
		expect(chatText(app)).toContain("hello");
		await app.submit("/clear");
		expect(chatText(app)).not.toContain("hello");
	});

	test("/clear-history empties SQLite in place even with persistence disabled", async () => {
		const dir = mkdtempSync(join(tmpdir(), "lemon-tui-history-"));
		teardown.push(() => rmSync(dir, { recursive: true, force: true }));
		const file = join(dir, "tui-history", "history.sqlite3");
		new PromptHistoryStore(file).append("old secret");
		const legacy = join(dir, "tui-history.jsonl");
		writeFileSync(legacy, `${JSON.stringify("legacy secret")}\n`, { mode: 0o600 });
		const { app, server } = await bootApp(
			"tui-test",
			process.cwd(),
			new PromptHistoryStore(file, { enabled: false }),
		);
		expect(app.editor.history).toEqual([]);
		app.editor.handleInput("local discarded draft");
		app.editor.handleInput("\x03");
		expect(app.editor.history).toEqual(["local discarded draft"]);
		app.editor.setText("/clear-history");
		app.editor.handleInput("\r");
		await waitFor(() => chatText(app).includes("prompt history cleared"), {
			what: "the editor's clear-history command",
		});
		expect(app.editor.history).toEqual([]);
		expect(existsSync(file)).toBe(true);
		expect(existsSync(legacy)).toBe(false);
		expect(new PromptHistoryStore(file).load()).toEqual([]);
		expect(server.requestsFor("chat.send")).toHaveLength(0);
	});

	test.skipIf(process.getuid?.() === 0)(
		"/clear-history cannot resurrect a retained legacy source after cleanup fails",
		async () => {
			const dir = mkdtempSync(join(tmpdir(), "lemon-tui-history-retained-"));
			teardown.push(() => rmSync(dir, { recursive: true, force: true }));
			const file = join(dir, "tui-history", "history.sqlite3");
			new PromptHistoryStore(file).append("old secret");
			const legacy = join(dir, "tui-history.jsonl");
			writeFileSync(legacy, `${JSON.stringify("retained secret")}\n`, { mode: 0o600 });
			const { app } = await bootApp(
				"tui-test",
				process.cwd(),
				new PromptHistoryStore(file, { enabled: false }),
			);
			// SQLite can still write inside its 0700 child directory, but removal
			// of a source in this non-writable parent must fail with real EACCES.
			chmodSync(dir, 0o500);
			try {
				app.editor.handleInput("local discarded secret");
				app.editor.handleInput("\x03");
				app.editor.setText("/clear-history");
				app.editor.handleInput("\r");
				await waitFor(
					() => /persistent\s+history\s+could\s+not\s+be\s+cleared/.test(chatText(app)),
					{
						what: "the persistent-history failure notice",
					},
				);
				expect(app.editor.history).toEqual([]);
				expect(chatText(app)).not.toMatch(/(?:^|\n)prompt history cleared(?:\n|$)/);
				expect(existsSync(file)).toBe(true);
				expect(existsSync(legacy)).toBe(true);
			} finally {
				chmodSync(dir, 0o700);
			}
			expect(new PromptHistoryStore(file).load()).toEqual([]);
		},
	);

	test("a history load permission failure becomes a startup warning", async () => {
		const dir = mkdtempSync(join(tmpdir(), "lemon-tui-history-load-"));
		teardown.push(() => rmSync(dir, { recursive: true, force: true }));
		const store = new PromptHistoryStore(join(dir, "tui-history", "history.sqlite3"));
		const load = spyOn(store, "load").mockImplementation(() => {
			throw new Error("EACCES: history directory denied");
		});
		try {
			const { app } = await bootApp("tui-test", process.cwd(), store);
			await waitFor(() => chatText(app).includes("prompt history could not be loaded"), {
				what: "the history startup warning",
			});
			expect(chatText(app)).toContain("EACCES: history directory denied");
			app.editor.handleInput("still usable");
			app.editor.handleInput("\x03");
			app.editor.handleInput("\x1b[A");
			expect(app.editor.getText()).toBe("still usable");
		} finally {
			load.mockRestore();
		}
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
			model: "openai:gpt-4o",
			thinkingLevel: "high",
		});
		expect(chatText(app)).toContain(id);
		expect(chatText(app)).toContain("Background work finished.");
	});
});

describe("file-defined slash commands", () => {
	test("are registered locally and delivered verbatim for the daemon to expand", async () => {
		const project = mkdtempSync(join(tmpdir(), "lemon-tui-project-"));
		teardown.push(() => rmSync(project, { recursive: true, force: true }));
		mkdirSync(join(project, ".claude/commands/git"), { recursive: true });
		writeFileSync(
			join(project, ".claude/commands/review.md"),
			"---\ndescription: Review a path\nargument-hint: <path>\n---\nReview $1",
		);
		writeFileSync(join(project, ".claude/commands/git/commit.md"), "Commit $ARGUMENTS");
		writeFileSync(join(project, ".claude/commands/help.md"), "shadowed by /help");
		const { app, server } = await bootApp("tui-test", project);

		await app.submit("/review lib/app.ex");
		await waitFor(() => server.requestsFor("chat.send").length > 0, { what: "chat.send" });
		expect(server.requestsFor("chat.send")[0].params).toMatchObject({
			prompt: "/review lib/app.ex",
		});

		// Namespaced names are plain prompt text to the client; the daemon expands them.
		const nested = await bootApp("tui-nested", project);
		await nested.app.submit("/git:commit fix it");
		await waitFor(() => nested.server.requestsFor("chat.send").length > 0, { what: "chat.send" });
		expect(nested.server.requestsFor("chat.send")[0].params).toMatchObject({
			prompt: "/git:commit fix it",
		});
		expect(chatText(app)).not.toContain("unknown command");

		// A command file named help.md must not shadow the built-in /help.
		await app.submit("/help");
		expect(chatText(app)).toContain("/review <path>");
		expect(server.requestsFor("chat.send")).toHaveLength(1);

		app.editor.handleInput("\x1b\r");
		await app.submit("/review lib/second.ex");
		expect(server.requestsFor("chat.send")[1].params).toMatchObject({
			prompt: "/review lib/second.ex",
			queueMode: "steer",
		});
		expect(app.effectiveMode).toBe("queue");
		await app.submit("ordinary followup");
		expect(server.requestsFor("chat.send")).toHaveLength(2);
		expect(app.store.queue.length("tui-test")).toBe(1);
	});
});

describe("typed slash input and command discovery", () => {
	test.each(["quit", "exit"])("/%s exits with the first Enter", async (name) => {
		const { app, terminal, exits, server } = await bootApp();
		terminal.sendInput("/");
		expect(app.selectors.isOpen).toBe(true);
		// MemoryTerminal delivers parsed keys, not the raw PTY byte stream.
		for (const key of `${name}\r`) terminal.sendInput(key);
		expect(exits).toEqual([0]);
		expect(app.selectors.isOpen).toBe(false);
		expect(app.editor.getText()).toBe("");
		expect(server.requestsFor("chat.send")).toHaveLength(0);
	});

	test("command arguments transfer to the editor and submit only on Enter", async () => {
		const { app, terminal, server } = await bootApp();
		for (const key of "/model") terminal.sendInput(key);
		expect(app.selectors.isOpen).toBe(true);
		terminal.sendInput(" gpt-4");
		expect(app.selectors.isOpen).toBe(false);
		expect(app.tui.getFocused()).toBe(app.editor);
		expect(app.editor.getText()).toBe("/model gpt-4");
		terminal.sendInput("o");
		expect(app.editor.getText()).toBe("/model gpt-4o");
		expect(server.requestsFor("sessions.patch")).toHaveLength(0);
		terminal.sendInput("\r");
		await waitFor(() => stripAnsi(app.statusBar.render(120)[0]).includes("gpt-4o"), {
			what: "the model typed through slash input",
		});
		expect(server.requestsFor("sessions.patch")[0].params).toMatchObject({
			model: "openai:gpt-4o",
		});
		expect(server.requestsFor("chat.send")).toHaveLength(0);
	});

	test.each([
		["qui", "quit"],
		["quit", "quit"],
		["rese", "reset"],
		["reset", "reset"],
	])("Ctrl+P query %s only inserts /%s and retains the draft", async (query, name) => {
		const { app, terminal, exits, server } = await bootApp();
		app.editor.setText("unfinished\n  draft");
		terminal.sendInput(CTRL_P);
		terminal.sendInput(query);
		terminal.sendInput("\r");
		expect(app.selectors.isOpen).toBe(false);
		expect(app.editor.getText()).toBe(`/${name} unfinished\n  draft`);
		expect(exits).toEqual([]);
		expect(server.requestsFor("sessions.reset")).toHaveLength(0);
		expect(server.requestsFor("chat.send")).toHaveLength(0);
	});

	test("Escape retains the typed slash query but Ctrl+P preserves the original draft", async () => {
		const { app, terminal, exits } = await bootApp();
		for (const key of "/qui") terminal.sendInput(key);
		terminal.sendInput("\x1b");
		expect(app.selectors.isOpen).toBe(false);
		expect(app.editor.getText()).toBe("/qui");
		terminal.sendInput(CTRL_P);
		terminal.sendInput("t");
		terminal.sendInput("\x1b");
		expect(app.editor.getText()).toBe("/qui");
		expect(exits).toEqual([]);
	});

	test("a slash inside an existing draft stays ordinary editor input", async () => {
		const { app, terminal } = await bootApp();
		app.editor.handleInput("unfinished");
		terminal.sendInput("/");
		expect(app.selectors.isOpen).toBe(false);
		expect(app.editor.getText()).toBe("unfinished/");
	});

	test("/palette keeps its explicit query in safe discovery mode", async () => {
		const { app, terminal, exits } = await bootApp();
		await app.submit("/palette quit");
		expect(app.selectors.isOpen).toBe(true);
		terminal.sendInput("\r");
		expect(app.selectors.isOpen).toBe(false);
		expect(app.editor.getText()).toBe("/quit ");
		expect(exits).toEqual([]);
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
	let previousShell: string | undefined;
	beforeEach(() => {
		previousShell = process.env.LEMON_TUI_SHELL;
		// Exercise the real subprocess path without user-shell startup files.
		process.env.LEMON_TUI_SHELL = "/bin/sh";
	});
	afterEach(() => {
		if (previousShell === undefined) delete process.env.LEMON_TUI_SHELL;
		else process.env.LEMON_TUI_SHELL = previousShell;
	});

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
