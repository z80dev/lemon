import { afterEach, beforeEach, expect, test } from "bun:test";
import { AppShell } from "../../src/app.ts";
import type { NotificationMode } from "../../src/config.ts";
import { DEFAULT_METHODS, FakeControlPlane } from "../../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import type { UserPromptRequested } from "../../src/protocol/user-prompt.ts";
import { detectTerminalCapabilities } from "../../src/terminal/capabilities.ts";
import { TerminalIntegration } from "../../src/terminal/integration.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal, renderPlain } from "../helpers/memory-terminal.ts";
import { waitFor } from "../helpers/wait.ts";

const SESSION = "tui-user-prompts";
const teardown: Array<() => void> = [];
beforeEach(() => initTheme({ colorLevel: 3 }));
afterEach(() => {
	while (teardown.length) teardown.pop()?.();
	resetTheme();
	invalidateThemeAdapters();
});

async function boot(notifications?: NotificationMode) {
	const server = await FakeControlPlane.start({
		methods: [...DEFAULT_METHODS, "sessions.prompt.bind", "sessions.prompt.resolve"],
	});
	teardown.push(() => server.stop());
	server.onMethod("sessions.prompt.bind", (params: { sessionKey: string; enabled: boolean }) => ({
		sessionKey: params.sessionKey,
		bound: params.enabled,
	}));
	server.onMethod("sessions.prompt.resolve", (params: { promptId: string }) => ({
		resolved: true,
		promptId: params.promptId,
	}));
	server.onMethod("chat.send", (params: { sessionKey: string }) => ({
		runId: "run-1",
		sessionKey: params.sessionKey,
	}));
	const terminal = new MemoryTerminal();
	const client = new ControlPlaneClient({
		url: server.url,
		socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
	});
	const app = new AppShell({
		url: server.url,
		sessionKey: SESSION,
		client,
		terminal,
		smoothStreaming: false,
	});
	teardown.push(() => app.stop());
	await app.start();
	if (notifications) {
		const integration = new TerminalIntegration(
			terminal,
			app.store,
			client,
			"/repo",
			detectTerminalCapabilities({ TERM_PROGRAM: "iTerm.app" }, true, notifications),
		);
		integration.start();
		teardown.push(() => integration.stop());
	}
	return { app, server, terminal };
}

function request(overrides: Partial<UserPromptRequested> = {}): UserPromptRequested {
	return {
		promptId: "prompt-1",
		sessionKey: SESSION,
		runId: "run-1",
		questions: [
			{
				id: "color",
				question: "Choose a color",
				options: [{ label: "BLUE" }, { label: "ORANGE" }],
				recommended: 1,
			},
		],
		...overrides,
	};
}

test.each(["auto", "off", "bell"] as const)(
	"opening a question uses %s notification mode without leaking question text",
	async (mode) => {
		const { app, server, terminal } = await boot(mode);
		terminal.writes.length = 0;
		const event = request({
			questions: [{ id: "q", question: "PRIVATE QUESTION \x1b]9;injected\x07", options: [] }],
		});
		server.pushEvent("session.prompt.requested", event);
		await waitFor(() => app.userPrompts.panel.visible);
		const signals = () =>
			terminal.writes.filter(
				(write) =>
					write === "\x07" ||
					write.startsWith("\x1b]9;Lemon:") ||
					write.startsWith("\x1b]777;notify;"),
			);
		expect(signals()).toEqual(
			mode === "off"
				? []
				: mode === "bell"
					? ["\x07"]
					: ["\x1b]9;Lemon: Question waiting — Return to Lemon to answer\x07"],
		);
		// Replayed events and session switches must not notify twice.
		app.client.events.emit("session.prompt.requested", event);
		app.store.setFocused("other");
		app.store.setFocused(SESSION);
		expect(signals()).toHaveLength(mode === "off" ? 0 : 1);
	},
);

test("binds the live TUI surface before submitting a chat", async () => {
	const { app, server } = await boot();
	await app.submit("investigate");
	const methods = server.received.map((entry) => entry.method);
	expect(methods.indexOf("sessions.prompt.bind")).toBeGreaterThanOrEqual(0);
	expect(methods.indexOf("sessions.prompt.bind")).toBeLessThan(methods.indexOf("chat.send"));
	expect(server.requestsFor("sessions.prompt.bind")[0]!.params).toEqual({
		sessionKey: SESSION,
		enabled: true,
	});
});

test("a question renders inert text, owns focus, and sends only the explicitly selected answer", async () => {
	const { app, server, terminal } = await boot();
	server.pushEvent(
		"session.prompt.requested",
		request({
			questions: [
				{
					id: "q",
					question: "Choose\u001b[31m a color\u001b[0m",
					options: [{ label: "BLUE" }, { label: "ORANGE" }],
					recommended: 1,
				},
			],
		}),
	);
	await waitFor(() => app.userPrompts.panel.visible);
	const text = renderPlain(app.userPromptContainer.render(80));
	expect(text).toContain("Choose a color");
	expect(text).toContain("ORANGE (recommended)");
	expect(app.tui.getFocused()).toBe(app.userPrompts.panel);
	expect(server.requestsFor("sessions.prompt.resolve")).toHaveLength(0);
	terminal.sendInput("\r");
	const answer = await server.waitForRequest("sessions.prompt.resolve");
	expect(answer.params).toEqual({
		promptId: "prompt-1",
		sessionKey: SESSION,
		runId: "run-1",
		action: "accept",
		content: { q0: "BLUE" },
	});
	await waitFor(() => !app.userPrompts.panel.visible);
	expect(app.tui.getFocused()).toBe(app.editor);
	expect(server.requestsFor("exec.approval.resolve")).toHaveLength(0);
});

test("multiple questions preserve multi-select and custom text answers", async () => {
	const { app, server, terminal } = await boot();
	server.pushEvent(
		"session.prompt.requested",
		request({
			questions: [
				{
					id: "multi",
					question: "Pick both",
					options: [{ label: "A" }, { label: "B" }],
					multi: true,
				},
				{ id: "text", question: "Explain your choice", options: [] },
			],
		}),
	);
	await waitFor(() => app.userPrompts.panel.visible);
	terminal.sendInput("\r");
	expect(renderPlain(app.userPromptContainer.render(80))).toContain("Question 1/2");
	terminal.sendInput(" ");
	terminal.sendInput("\x1b[B");
	terminal.sendInput(" ");
	terminal.sendInput("\r");
	expect(renderPlain(app.userPromptContainer.render(80))).toContain("Explain your choice");
	terminal.sendInput("Actual explanation");
	terminal.sendInput("\r");
	const answer = await server.waitForRequest("sessions.prompt.resolve");
	expect(answer.params).toMatchObject({
		action: "accept",
		content: { q0: ["A", "B"], q1__other: "Actual explanation" },
	});
});

test("Escape declines without choosing a recommendation", async () => {
	const { app, server, terminal } = await boot();
	server.pushEvent("session.prompt.requested", request());
	await waitFor(() => app.userPrompts.panel.visible);
	terminal.sendInput("\x1b");
	const answer = await server.waitForRequest("sessions.prompt.resolve");
	expect(answer.params).toMatchObject({ action: "decline" });
	expect(answer.params).not.toHaveProperty("content");
	await waitFor(() => !app.userPrompts.panel.visible);
});

test("expiry dismisses the matching prompt with no local answer", async () => {
	const { app, server } = await boot();
	server.pushEvent("session.prompt.requested", request());
	await waitFor(() => app.userPrompts.panel.visible);
	const observed = Promise.withResolvers<void>();
	const off = app.client.events.on("session.prompt.resolved", () => observed.resolve());
	server.pushEvent("session.prompt.resolved", {
		promptId: "prompt-1",
		sessionKey: SESSION,
		runId: "foreign",
		status: "timed_out",
	});
	await observed.promise;
	off();
	expect(app.userPrompts.panel.visible).toBe(true);
	server.pushEvent("session.prompt.resolved", {
		promptId: "prompt-1",
		sessionKey: SESSION,
		runId: "run-1",
		status: "timed_out",
	});
	await waitFor(() => !app.userPrompts.panel.visible);
	expect(server.requestsFor("sessions.prompt.resolve")).toHaveLength(0);
});

test("failed or malformed resolution keeps the question actionable", async () => {
	const { app, server, terminal } = await boot();
	server.respondWith("sessions.prompt.resolve", { resolved: false, promptId: "prompt-1" });
	server.pushEvent("session.prompt.requested", request());
	await waitFor(() => app.userPrompts.panel.visible);
	terminal.sendInput("\r");
	await waitFor(() => renderPlain(app.chatContainer.render(80)).includes("did not confirm"));
	expect(app.userPrompts.panel.visible).toBe(true);
	expect(app.userPrompts.panel.busy).toBe(false);
});

test("questions stay scoped to the selected session", async () => {
	const { app, server } = await boot();
	const observed = Promise.withResolvers<void>();
	const off = app.client.events.on("session.prompt.requested", () => observed.resolve());
	server.pushEvent("session.prompt.requested", request({ sessionKey: "other" }));
	await observed.promise;
	off();
	expect(app.userPrompts.panel.visible).toBe(false);
	app.store.setFocused("other");
	await waitFor(() => app.userPrompts.panel.visible);
	expect(renderPlain(app.userPromptContainer.render(80))).toContain("Choose a color");
	app.store.setFocused(SESSION);
	expect(app.userPrompts.panel.visible).toBe(false);
});
