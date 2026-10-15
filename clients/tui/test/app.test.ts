import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import { AppShell } from "../src/app.ts";
import { imageFromBytes } from "../src/composer/images.ts";
import { DEFAULT_METHODS, FakeControlPlane } from "../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../src/protocol/client.ts";
import { newSessionKey } from "../src/session-key.ts";
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

async function bootApp(sessionKey = "tui-test", keybindings?: unknown, methods = DEFAULT_METHODS) {
	const server = await FakeControlPlane.start({ methods });
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
		keybindings,
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
	test("bound plan and model actions reach the existing command and picker paths", async () => {
		const { app, server, terminal } = await bootApp(
			"tui-keys",
			{
				"lemon.plan.toggle": "alt+p",
				"lemon.model.cycle": "alt+v",
				"lemon.editor.external": "none",
				"tui.editor.cursorLeft": "alt+h",
			},
			[...DEFAULT_METHODS, "sessions.plan"],
		);
		server.onMethod("sessions.plan", (params: { sessionKey: string; action: string }) => ({
			sessionKey: params.sessionKey,
			plan: { mode: params.action === "enter" ? "plan" : "code", path: null, content: null },
		}));
		server.respondWith("models.list", {
			models: [
				{ id: "first", provider: "test" },
				{ id: "next", provider: "test" },
			],
		});
		server.respondWith("sessions.patch", { success: true });
		app.session.setModel({ model: "test:first", provider: "test" }, "local");
		terminal.sendInput("\x1bp");
		await waitForText(() => chatText(app), "plan mode on");
		expect(app.session.planMode).toBe("plan");
		terminal.sendInput("\x1bv");
		await waitForText(() => chatText(app), "model: test:next");
		expect(app.session.model).toBe("test:next");
		expect(server.requestsFor("sessions.patch").at(-1)?.params).toEqual({
			sessionKey: "tui-keys",
			model: "test:next",
		});
		// pi-tui's editor consumes the same configured manager as the globals.
		app.editor.setText("ab");
		terminal.sendInput("\x1bh");
		terminal.sendInput("x");
		expect(app.editor.getText()).toBe("axb");
	});

	test("restores a cold launch session before accepting native delegation", async () => {
		const server = await FakeControlPlane.start();
		teardown.push(() => server.stop());
		const history = Promise.withResolvers<{
			messages: Array<{ id: string; role: string; content: string }>;
		}>();
		server.onMethod("chat.history", () => history.promise);
		server.respondWith("chat.send", { runId: "fork-next", sessionKey: "saved-fork" });
		const app = new AppShell({
			url: server.url,
			sessionKey: "saved-fork",
			terminal: new MemoryTerminal(),
		});
		teardown.push(() => app.stop());
		const starting = app.start();
		await server.waitForRequest("chat.history");
		const send = { type: "send" as const, key: "", text: "continue the branch" };
		app.editor.handleNativeEvent(send);
		expect(server.requestsFor("chat.send")).toHaveLength(0);
		history.resolve({
			messages: [
				{ id: "u1", role: "user", content: "remember the saved branch" },
				{ id: "a1", role: "assistant", content: "saved branch answer" },
			],
		});
		await starting;
		expect(chatText(app)).toContain("saved branch answer");
		app.editor.handleNativeEvent(send);
		const request = await server.waitForRequest("chat.send");
		expect(request.params).toMatchObject({ prompt: "continue the branch" });
		expect(chatText(app).match(/saved branch answer/g)).toHaveLength(1);
	});

	test("submitting a prompt sends chat.send for the active session", async () => {
		const { app, server } = await bootApp("tui-session-a");
		await app.submit("what is the status?");

		const frame = server.requestsFor("chat.send")[0];
		expect(frame.params).toEqual({
			sessionKey: "tui-session-a",
			prompt: "what is the status?",
			cwd: process.cwd(),
		});
		expect(chatText(app)).toContain("what is the status?");
	});

	test("blank submissions are ignored", async () => {
		const { app, server } = await bootApp();
		await app.submit("   \n  ");
		expect(server.requestsFor("chat.send")).toHaveLength(0);
	});

	test("multi-picker toggles choices with Space and confirms with Enter", async () => {
		const { app, terminal } = await bootApp();
		const confirmed: string[][] = [];
		app.host.openMultiPicker({
			title: "Choose skills",
			items: [
				{ value: "arxiv", label: "arxiv" },
				{ value: "notes", label: "notes" },
			],
			onConfirm: (items) => {
				confirmed.push(items.map((item) => item.value));
			},
		});

		terminal.sendInput(" ");
		terminal.sendInput("\r");
		await Bun.sleep(10);

		expect(confirmed).toEqual([["arxiv"]]);
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

	test("fresh sessions are distinct canonical local channel peers", () => {
		const key = newSessionKey();
		expect(key).toMatch(/^agent:default:tui:local:dm:[0-9a-f-]{36}$/);
		expect(newSessionKey()).not.toBe(key);
	});
});

const PNG = Buffer.from(
	"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1iUAAAAASUVORK5CYII=",
	"base64",
);

test("image-only composer submission sends bytes and clears attachments only after the run receipt", async () => {
	const { app, server } = await bootApp();
	const image = imageFromBytes(PNG, "pixel.png");
	app.composerDrafts.add(app.sessionKey, [image]);
	await app.editor.submitComposer();
	expect(server.requestsFor("chat.send")[0]?.params).toMatchObject({
		prompt: "",
		images: [image.content],
		sessionKey: app.sessionKey,
	});
	expect(app.editor.pendingAttachments).toHaveLength(0);
	expect(chatText(app)).toContain("[image: pixel.png]");
});

test("refused image submissions retain both the image and text draft", async () => {
	const { app, server } = await bootApp();
	server.failWith("chat.send", "FORBIDDEN", "not allowed");
	const image = imageFromBytes(PNG, "pixel.png");
	app.composerDrafts.add(app.sessionKey, [image]);
	app.editor.setText("describe this");
	await app.editor.submitComposer();
	expect(app.editor.getExpandedText()).toBe("describe this");
	expect(app.editor.pendingAttachments).toEqual([image]);
});

test("queued media transfers ownership and a failed drain requires explicit review rather than auto-retry", async () => {
	const { app, server } = await bootApp();
	const image = imageFromBytes(PNG, "pixel.png");
	app.composerDrafts.add(app.sessionKey, [image]);
	app.store.focused.busy = true;
	await app.editor.submitComposer();
	expect(app.editor.pendingAttachments).toHaveLength(0);
	expect(app.store.queue.items(app.sessionKey)[0].attachments).toEqual([image]);
	app.store.focused.busy = false;
	server.failWith("chat.send", "UNAVAILABLE", "not accepted");
	await app.drainQueue(app.sessionKey);
	expect(app.store.queue.items(app.sessionKey)[0].state).toBe("needs-review");
	await app.drainQueue(app.sessionKey);
	expect(server.requestsFor("chat.send")).toHaveLength(1);
	app.editQueued(app.store.queue.items(app.sessionKey)[0]);
	expect(app.editor.pendingAttachments).toEqual([image]);
	expect(app.store.queue.items(app.sessionKey)).toHaveLength(0);
});

test("offline and external native sends cannot take ownership of pending human images", async () => {
	const { app, server } = await bootApp();
	const image = imageFromBytes(PNG, "pixel.png");
	app.composerDrafts.add(app.sessionKey, [image]);
	app.editor.setText("human question");
	app.editor.handleNativeEvent({ type: "send", key: "", text: "external delegated question" });
	expect(server.requestsFor("chat.send")).toHaveLength(0);
	app.client.close();
	await app.editor.submitComposer();
	expect(app.editor.pendingAttachments).toEqual([image]);
	expect(app.editor.getExpandedText()).toBe("human question");
	expect(app.client.queued).toHaveLength(0);
});

test("profile image payloads keep their authoritative route, including method refusals", async () => {
	const { app, server } = await bootApp("agent:proof:main");
	server.respondWith("profiles.get", {
		profile: { id: "proof", canonicalSessionKey: app.sessionKey },
	});
	server.failWith("profile.chat", "METHOD_NOT_FOUND", "unavailable");
	const image = imageFromBytes(PNG, "pixel.png");
	app.composerDrafts.add(app.sessionKey, [image]);
	app.editor.setText("describe this");
	await app.editor.submitComposer();
	expect(server.requestsFor("profile.chat")[0]?.params).toMatchObject({
		id: "proof",
		images: [image.content],
	});
	expect(server.requestsFor("chat.send")).toHaveLength(0);
	expect(app.editor.pendingAttachments).toEqual([image]);
});
