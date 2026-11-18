/**
 * Destructive session lifecycle through the real shell: `/reset` (and
 * `/session reset`) and the switcher's close preview first and act only on a
 * confirmation bound to the exact session key; the local copy is forgotten
 * only after the daemon verified the deletion, and an unknown outcome is
 * reported as unknown — never as "closed locally".
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { AppShell } from "../../src/app.ts";
import { DEFAULT_METHODS, FakeControlPlane } from "../../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import { resetBlockIds } from "../../src/store/transcript-model.ts";
import type { PickerOverlay } from "../../src/ui/components/pickers.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal, renderPlain } from "../helpers/memory-terminal.ts";
import { waitFor } from "../helpers/wait.ts";

const SESSION = "tui-lifecycle";
const CTRL_W = "\x17";

const teardown: Array<() => void> = [];

beforeEach(() => {
	resetBlockIds();
	initTheme({ colorLevel: 3 });
});

afterEach(() => {
	while (teardown.length > 0) teardown.pop()?.();
	resetTheme();
	invalidateThemeAdapters();
});

const VERIFIED_RESET = {
	success: true,
	sessionKey: SESSION,
	summary: { sessionKey: SESSION, reset: true, cleanup: { deletedRunHistory: true } },
};

async function boot(
	options: { requestTimeoutMs?: number; sessionKey?: string; methods?: string[] } = {},
) {
	const server = await FakeControlPlane.start({
		methods: [...DEFAULT_METHODS, ...(options.methods ?? [])],
	});
	teardown.push(() => server.stop());
	server.onMethod("chat.send", (params: { sessionKey: string }) => ({
		runId: "run-1",
		sessionKey: params.sessionKey,
	}));
	server.respondWith("chat.history", { messages: [] });
	server.respondWith("sessions.list", {
		sessions: [{ sessionKey: SESSION }, { sessionKey: "scratch", title: "scratch work" }],
	});
	server.respondWith("sessions.active.list", { sessions: [] });
	server.respondWith("exec.approvals.get", { approvals: [] });
	server.onMethod("sessions.get", (params: { sessionKey: string }) => ({
		session: { sessionKey: params.sessionKey, runCount: 3, pinned: false, archived: false },
	}));
	server.respondWith("sessions.reset", VERIFIED_RESET);
	const app = new AppShell({
		url: server.url,
		sessionKey: options.sessionKey ?? SESSION,
		version: "test",
		client: new ControlPlaneClient({
			url: server.url,
			requestTimeoutMs: options.requestTimeoutMs,
			socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
		}),
		terminal: new MemoryTerminal(),
		smoothStreaming: false,
	});
	teardown.push(() => app.stop());
	await app.start();
	return { app, server };
}

function chat(app: AppShell): string {
	return renderPlain(app.chatContainer.render(160));
}

/** Seed a visible exchange so a local reset is observable. */
function seed(app: AppShell, key = SESSION): void {
	app.store.session(key).addUser("keep me");
	app.events.rebuildFocused();
}

describe("/reset", () => {
	test.each(["/reset", "/session reset"])(
		"%s previews and sends nothing until the exact key confirms it",
		async (command) => {
			const { app, server } = await boot();
			seed(app);
			await app.submit(command);
			expect(server.requestsFor("sessions.reset")).toHaveLength(0);
			expect(chat(app)).toContain(`reset preview · ${SESSION}`);
			expect(chat(app)).toContain(`--confirm ${SESSION}`);
			expect(chat(app)).toContain("keep me");

			// A confirmation for another key is a cancel, not a reset.
			await app.submit(`${command} --confirm other-session`);
			expect(server.requestsFor("sessions.reset")).toHaveLength(0);
			expect(app.store.focused.blocks.some((b) => b.kind === "user")).toBe(true);

			await app.submit(`${command} --confirm ${SESSION}`);
			await waitFor(() => server.requestsFor("sessions.reset").length === 1, {
				what: "sessions.reset",
			});
			expect(server.requestsFor("sessions.reset")[0]!.params).toEqual({ sessionKey: SESSION });
			await waitFor(() => !app.store.focused.blocks.some((b) => b.kind === "user"), {
				what: "the local reset",
			});
		},
	);

	test("an unverified reset keeps the local transcript and says the outcome is unknown", async () => {
		const { app, server } = await boot();
		server.respondWith("sessions.reset", { ok: true });
		seed(app);
		await app.submit(`/reset --confirm ${SESSION}`);
		await waitFor(() => server.requestsFor("sessions.reset").length === 1, {
			what: "sessions.reset",
		});
		await waitFor(() => chat(app).includes("unknown"), { what: "the unknown outcome" });
		expect(app.store.focused.blocks.some((b) => b.kind === "user")).toBe(true);
		expect(chat(app)).not.toMatch(/history cleared/);
	});

	test("a busy session is not reset", async () => {
		const { app, server } = await boot();
		app.store.focused.busy = true;
		app.store.focused.activeRunId = "run-live";
		await app.submit(`/reset --confirm ${SESSION}`);
		expect(server.requestsFor("sessions.reset")).toHaveLength(0);
		expect(chat(app)).toContain("running");
	});

	/** Hold `sessions.reset` until the test releases it with a verified receipt. */
	function holdReset(server: FakeControlPlane) {
		const { promise, resolve } = Promise.withResolvers<typeof VERIFIED_RESET>();
		server.onMethod("sessions.reset", () => promise);
		return () => resolve(VERIFIED_RESET);
	}

	test("prompts are refused while the reset is in flight", async () => {
		const { app, server } = await boot();
		seed(app);
		const release = holdReset(server);
		const resetting = app.submit(`/reset --confirm ${SESSION}`);
		await waitFor(() => server.requestsFor("sessions.reset").length === 1, {
			what: "sessions.reset",
		});
		expect(app.store.focused.resetPending).toBe(true);
		expect(await app.sendPrompt("sneak this in")).toBe("rejected");
		expect(server.requestsFor("chat.send")).toHaveLength(0);
		expect(chat(app)).toContain("reset of this session is in flight");
		release();
		await resetting;
		expect(app.store.focused.resetPending).toBe(false);
		// The refusal notice is itself a change after the confirmed generation.
		expect(chat(app)).toContain("outcome unknown");
		expect(app.store.focused.blocks.some((b) => b.kind === "user")).toBe(true);
	});

	test("a run that starts before the verified reply lands is not wiped", async () => {
		const { app, server } = await boot();
		seed(app);
		const release = holdReset(server);
		const resetting = app.submit(`/reset --confirm ${SESSION}`);
		await waitFor(() => server.requestsFor("sessions.reset").length === 1, {
			what: "sessions.reset",
		});
		// Another client starts a run on the same session meanwhile.
		server.pushEvent("agent", { type: "started", runId: "remote-run", sessionKey: SESSION });
		server.pushEvent("chat", {
			type: "delta",
			runId: "remote-run",
			sessionKey: SESSION,
			seq: 1,
			text: "remote answer",
		});
		await waitFor(() => chat(app).includes("remote answer"), { what: "the remote run" });
		release();
		await resetting;
		await waitFor(() => chat(app).includes("outcome unknown"), { what: "the unknown outcome" });
		expect(chat(app)).toContain("remote answer");
		expect(app.store.focused.activeRunId).toBe("remote-run");
		expect(app.store.focused.blocks.some((b) => b.kind === "user")).toBe(true);
	});
});

describe("/reset against submissions still being prepared", () => {
	/** Answer `method` only when the test releases it. */
	function hold(server: FakeControlPlane, method: string, payload: unknown) {
		const { promise, resolve } = Promise.withResolvers<unknown>();
		server.onMethod(method, () => promise);
		return () => resolve(payload);
	}

	test.each([
		["sessions.prompt.bind", SESSION, { sessionKey: SESSION, bound: true }],
		[
			"profiles.get",
			"agent:alpha:main",
			{ profile: { id: "alpha", canonicalSessionKey: "agent:alpha:main" } },
		],
	] as const)(
		"a prompt held in %s blocks the reset, then still sends",
		async (method, sessionKey, payload) => {
			const { app, server } = await boot({ sessionKey, methods: ["sessions.prompt.bind"] });
			server.respondWith("sessions.prompt.bind", { sessionKey, bound: true });
			server.onMethod("profile.chat", () => ({ runId: "run-p", sessionKey }));
			const release = hold(server, method, payload);
			const sending = app.sendPrompt("first prompt");
			await waitFor(() => server.requestsFor(method).length === 1, { what: method });
			expect(app.store.focused.pendingSubmissions).toBe(1);

			await app.submit(`/reset --confirm ${sessionKey}`);
			expect(server.requestsFor("sessions.reset")).toHaveLength(0);
			expect(chat(app)).toContain("a prompt submission is still running");

			release();
			expect(await sending).toBe("accepted");
			expect(app.store.focused.pendingSubmissions).toBe(0);
			expect(
				server.requestsFor("chat.send").length + server.requestsFor("profile.chat").length,
			).toBe(1);
		},
	);

	test("dispatch rechecks the fence after its preparation awaits", async () => {
		const { app, server } = await boot({ methods: ["sessions.prompt.bind"] });
		const release = hold(server, "sessions.prompt.bind", { sessionKey: SESSION, bound: true });
		const sending = app.sendPrompt("raced prompt");
		await waitFor(() => server.requestsFor("sessions.prompt.bind").length === 1, {
			what: "the bind",
		});
		// A reset that got in by any route owns the session now.
		app.store.focused.resetPending = true;
		release();
		expect(await sending).not.toBe("accepted");
		expect(server.requestsFor("chat.send")).toHaveLength(0);
		app.store.focused.resetPending = false;
	});
});

describe("switcher close", () => {
	async function closeFromSwitcher(app: AppShell, key: string): Promise<void> {
		const opened = app.submit("/sessions");
		await waitFor(() => app.selectors.isOpen, { what: "the switcher" });
		await opened;
		const overlay = app.selectors.current as PickerOverlay;
		await waitFor(() => overlay.selected !== undefined, { what: "the rows" });
		for (let step = 0; step < 3 && overlay.selected?.value !== key; step++) {
			overlay.handleInput("\x1b[B");
		}
		expect(overlay.selected?.value).toBe(key);
		overlay.handleInput(CTRL_W);
		// Whatever is on screen now, Enter must not delete.
		app.selectors.current?.handleInput?.("\r");
	}

	test("closing from the switcher only previews /session delete, even when Enter follows", async () => {
		const { app, server } = await boot();
		server.failWith("sessions.delete", "UNAVAILABLE", "daemon down");
		app.store.session("scratch");
		await closeFromSwitcher(app, "scratch");
		await waitFor(() => chat(app).includes("delete preview · scratch"), { what: "the preview" });
		expect(chat(app)).toContain("/session delete scratch --confirm scratch");
		expect(server.requestsFor("sessions.delete")).toHaveLength(0);
		expect(app.store.sessions.has("scratch")).toBe(true);
		expect(chat(app)).not.toMatch(/closed .* locally/);
	});

	test.each([
		["fails", (server: FakeControlPlane) => server.failWith("sessions.delete", "UNAVAILABLE", "x")],
		["times out", (server: FakeControlPlane) => server.silenceMethod("sessions.delete")],
		[
			"is unverified",
			(server: FakeControlPlane) => server.respondWith("sessions.delete", { deleted: true }),
		],
	])(
		"a confirmed delete that %s keeps the session and never says 'closed locally'",
		async (_, script) => {
			const { app, server } = await boot({ requestTimeoutMs: 300 });
			app.store.session("scratch");
			script(server);
			await app.submit("/session delete scratch --confirm scratch");
			await waitFor(() => server.requestsFor("sessions.delete").length === 1, {
				what: "sessions.delete",
			});
			await waitFor(() => /did not complete|unknown|not verified/.test(chat(app)), {
				what: "the reported outcome",
				timeoutMs: 2000,
			});
			expect(app.store.sessions.has("scratch")).toBe(true);
			expect(chat(app)).not.toMatch(/closed .* locally/);
		},
	);

	test("the local copy is forgotten only after a verified deletion", async () => {
		const { app, server } = await boot();
		app.store.session("scratch");
		let presentWhileDeleting: boolean | undefined;
		server.onMethod("sessions.delete", (params: { sessionKey: string }) => {
			presentWhileDeleting = app.store.sessions.has(params.sessionKey);
			return { deleted: true, sessionKey: params.sessionKey, summary: { verified: true } };
		});
		await app.submit("/session delete scratch --confirm scratch");
		await waitFor(() => !app.store.sessions.has("scratch"), { what: "the local forget" });
		expect(presentWhileDeleting).toBe(true);
		expect(chat(app)).toContain("verified deletion of scratch");
	});
});
