/**
 * The Agent Hub through the real shell and wire protocol: Alt+A, `/hub`, the
 * `subagents.*` roster, transcript, message and cancel against the fake
 * control plane's session-scoped fixtures.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { AppShell } from "../../src/app.ts";
import {
	FakeControlPlane,
	installSubagentFixtures,
	SUBAGENT_FAKE_METHODS,
} from "../../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import { METHOD } from "../../src/protocol/methods.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal, renderPlain } from "../helpers/memory-terminal.ts";
import { waitFor } from "../helpers/wait.ts";

const ALT_A = "\x1ba";
const KEY = "tui-hub";
const teardown: Array<() => void> = [];

beforeEach(() => initTheme({ colorLevel: 0 }));
afterEach(() => {
	while (teardown.length > 0) teardown.pop()?.();
	resetTheme();
	invalidateThemeAdapters();
});

async function bootApp() {
	const server = await FakeControlPlane.start({ methods: [...SUBAGENT_FAKE_METHODS] });
	teardown.push(() => server.stop());
	const fake = installSubagentFixtures(server, {
		[KEY]: [
			{
				taskId: "lead",
				status: "running",
				depth: 0,
				name: "Lead",
				agent: "task",
				description: "Coordinate the parser work",
				model: "anthropic/claude-sonnet-4-5",
				activity: "reading lib/parser.ex",
				usage: { tokens: 1_500, requests: 2 },
				messaging: true,
				cancellable: true,
				transcript: "Parser mapped; checking tests next.",
			},
			{
				taskId: "nested",
				status: "parked",
				depth: 1,
				parentTaskId: "lead",
				name: "Scout",
				agent: "scout",
				messaging: true,
				cancellable: true,
			},
		],
		"tui-other": [{ taskId: "foreign", status: "running", name: "Foreign" }],
	});
	server.respondWith("chat.history", { messages: [] });
	const terminal = new MemoryTerminal();
	const client = new ControlPlaneClient({
		url: server.url,
		socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
	});
	const app = new AppShell({
		url: server.url,
		sessionKey: KEY,
		version: "test",
		client,
		terminal,
		cwd: "/work/lemon",
		readBranch: async () => "main",
	});
	teardown.push(() => app.stop());
	await app.start();
	await waitFor(() => client.online, { what: "handshake" });
	const dock = () => renderPlain(app.statusContainer.render(200));
	return { app, server, fake, terminal, dock };
}

describe("Agent Hub in the app", () => {
	test("Alt+A lists the session's agents; Enter opens a transcript; typing revives", async () => {
		const { app, server, fake, terminal, dock } = await bootApp();
		terminal.sendInput(ALT_A);
		await waitFor(() => dock().includes("agents · 1 running · 1 parked"), {
			what: "roster from subagents.list",
		});
		expect(server.requestsFor(METHOD.subagentsList)[0]?.params).toEqual({ sessionKey: KEY });
		const roster = dock();
		expect(roster).toContain("Lead @task · lead · anthropic/claude-sonnet-4-5 · 1.5k tok 2 req");
		expect(roster).toContain("└─ parked");
		expect(roster).not.toContain("Foreign");

		terminal.sendInput("\x1b[B");
		terminal.sendInput("\r");
		await waitFor(() => dock().includes("revive ›") && dock().includes("Status: parked"), {
			what: "transcript view",
		});
		for (const key of "continue please") terminal.sendInput(key);
		terminal.sendInput("\r");
		await waitFor(() => fake.sent.length === 1, { what: "subagents.send" });
		expect(fake.sent[0]).toEqual({ sessionKey: KEY, taskId: "nested", message: "continue please" });
		await waitFor(() => dock().includes("revived nested"));
		await waitFor(() => dock().includes("operator: continue please"), {
			what: "transcript refresh",
		});

		terminal.sendInput("\x1b");
		await waitFor(() => dock().includes("enter transcript & message"));
		terminal.sendInput("\x1b");
		await waitFor(() => !dock().includes("agents ·"));
		expect(app.tui.getFocused()).toBe(app.editor);
	});

	test("/hub opens the hub and x x cancels the selected agent", async () => {
		const { app, server, fake, terminal, dock } = await bootApp();
		await app.submit("/hub");
		await waitFor(() => dock().includes("agents · 1 running"));
		terminal.sendInput("x");
		await waitFor(() => dock().includes("press x again to cancel Lead"));
		expect(server.requestsFor(METHOD.subagentsCancel)).toHaveLength(0);
		terminal.sendInput("x");
		await waitFor(() => dock().includes("cancelled lead"));
		expect(server.requestsFor(METHOD.subagentsCancel)[0]?.params).toEqual({
			sessionKey: KEY,
			taskId: "lead",
		});
		expect(fake.sessions.get(KEY)?.[0]?.status).toBe("cancelled");
		await waitFor(() => dock().includes("cancelled") && dock().includes("1 done"));
	});
});
