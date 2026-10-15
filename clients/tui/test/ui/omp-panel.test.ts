import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import {
	DEFAULT_METHODS,
	FakeControlPlane,
	installOmpFixtures,
	OMP_FAKE_EVENTS,
	OMP_FAKE_METHODS,
} from "../../src/dev/fake-server.ts";
import { OMP_FIXTURE_NOW, ompSessionWire } from "../../src/dev/fixtures/omp-fixtures.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import { RequestTimeoutError } from "../../src/protocol/errors.ts";
import { ControlPlaneMethods, METHOD } from "../../src/protocol/methods.ts";
import { OmpStore } from "../../src/store/omp-store.ts";
import type { NoticeLevel } from "../../src/store/transcript-model.ts";
import { OmpController } from "../../src/ui/controllers/omp-controller.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { renderPlain, TERMINAL_CONTROLS } from "../helpers/memory-terminal.ts";
import { waitFor } from "../helpers/wait.ts";

const ENTER = "\r";
const ESC = "\u001b";
const DOWN = "\u001b[B";

const teardown: Array<() => void> = [];
beforeEach(() => initTheme({ colorLevel: 0 }));
afterEach(() => {
	for (const fn of teardown.splice(0)) fn();
	resetTheme();
});

async function boot(options: { methods?: readonly string[]; available?: boolean } = {}) {
	const server = await FakeControlPlane.start({
		methods: [...(options.methods ?? OMP_FAKE_METHODS)],
		events: [...OMP_FAKE_EVENTS],
	});
	const fake = installOmpFixtures(server, { available: options.available });
	const client = new ControlPlaneClient({ url: server.url });
	const store = new OmpStore();
	const notices: Array<{ text: string; level?: NoticeLevel }> = [];
	let blurred = 0;
	const methods = new ControlPlaneMethods(client);
	const controller = new OmpController({
		store,
		methods,
		client,
		cwd: "/work/lemon",
		requestRender: () => {},
		onBlur: () => {
			blurred += 1;
		},
		notice: (text, level) => notices.push({ text, level }),
		now: () => OMP_FIXTURE_NOW,
	});
	teardown.push(() => {
		controller.dispose();
		client.close();
		server.stop();
	});
	controller.attach();
	await client.connect();
	const panel = controller.panel;
	const rendered = () => renderPlain(panel.render(240));
	/** Printable text one character at a time; a whole key sequence (arrows, Escape) as one input. */
	const type = (text: string) => {
		if (text.startsWith("\u001b")) panel.handleInput(text);
		else for (const char of text) panel.handleInput(char);
	};
	return {
		server,
		fake,
		client,
		methods,
		store,
		controller,
		panel,
		notices,
		rendered,
		type,
		blurred: () => blurred,
	};
}

async function opened(options?: Parameters<typeof boot>[0]) {
	const app = await boot(options);
	if (!options?.methods || options.methods.includes(METHOD.ompSessionsList)) {
		await waitFor(() => app.store.size === 3, { what: "initial omp list" });
	}
	app.controller.setVisible(true);
	app.panel.focused = true;
	return app;
}

describe("omp panel", () => {
	test("lists live and recent sessions after the handshake", async () => {
		const { rendered, server } = await opened();
		expect(server.requestsFor(METHOD.ompSessionsList)[0]?.params).toEqual({
			includeEnded: true,
			limit: 50,
		});
		const text = rendered();
		expect(text).toContain("omp · 2 live · 1 running · 1 ended");
		expect(text).toContain(
			"▶ Fix the flaky reconnect test · running · lemon · deepseek/deepseek-v4-flash · Running bash — bun test test/protocol/ws.test.ts · 1m35s · 41k tok · $0.0018 · ctx 18%",
		);
		expect(text).toContain("○ Summarise the release notes · idle · completed");
		expect(text).toContain("s steer · f follow-up · R redirect");
	});

	test("untrusted omp text never reaches the terminal as control sequences", async () => {
		const { panel, rendered, type } = await opened();
		expect(panel.render(140).join("\n")).not.toMatch(TERMINAL_CONTROLS);
		expect(rendered()).toContain("✗ Hostile title red · failed · error");
		type(DOWN);
		type(DOWN);
		panel.handleInput(ENTER);
		const detail = panel.render(140).join("\n");
		expect(detail).not.toMatch(TERMINAL_CONTROLS);
		expect(detail).toContain("error provider error: rate limited");
		expect(detail).toContain("1 interactive omp prompt(s) declined (headless)");
		const native = JSON.stringify(panel.describe());
		expect(native).not.toMatch(/\\u001b|\\u0007/);
		expect(native).toContain("Hostile title red");
	});

	test("Enter opens the detail and returns to the list", async () => {
		const { panel, rendered } = await opened();
		panel.handleInput(ENTER);
		expect(panel.mode).toBe("detail");
		const detail = rendered();
		expect(detail).toContain("omp · Fix the flaky reconnect test (omp_3f9a1c2b7d4e)");
		expect(detail).toContain("activity Running bash");
		expect(detail).toContain("▶ bash — Re-running the reconnect suite");
		expect(detail).toContain("todos 2/4");
		expect(detail).toContain("[>] Fix: Make the watchdog deterministic");
		panel.handleInput(ENTER);
		expect(panel.mode).toBe("list");
	});

	test("live omp.session events update the panel", async () => {
		const { server, rendered } = await opened();
		server.pushEvent("omp.session", {
			reason: "settled",
			session: ompSessionWire({
				status: "idle",
				lastTurn: "completed",
				activity: null,
				updatedAt: Date.now(),
			}),
		});
		await waitFor(() => rendered().includes("○ Fix the flaky reconnect test · idle · completed"));
		expect(rendered()).toContain("0 running");
	});

	test("s steers the selected session and clears the field on acceptance", async () => {
		const { panel, server, type, notices } = await opened();
		type("s");
		expect(panel.prompt?.mode).toBe("steer");
		type("use the fake clock");
		panel.handleInput(ENTER);
		const request = await server.waitForRequest(METHOD.ompSessionsSend);
		expect(request.params).toEqual({
			id: "omp_3f9a1c2b7d4e",
			message: "use the fake clock",
			mode: "steer",
		});
		await waitFor(() => panel.prompt === undefined);
		expect(panel.flash).toEqual({ text: "steer accepted by omp_3f9a1c2b7d4e", level: "info" });
		expect(notices.at(-1)?.text).toBe("omp: steer accepted by omp_3f9a1c2b7d4e");
	});

	test("f sends a follow-up; an idle session reports its actual delivery", async () => {
		const { panel, server, type } = await opened();
		type(DOWN);
		type("f");
		type("next");
		panel.handleInput(ENTER);
		const request = await server.waitForRequest(METHOD.ompSessionsSend);
		expect(request.params).toMatchObject({ id: "omp_8c21aa90e5f1", mode: "followUp" });
		await waitFor(() => panel.prompt === undefined);
		expect(panel.flash?.text).toBe("follow-up accepted by omp_8c21aa90e5f1 (delivered as prompt)");
	});

	test("a refused message is reported and kept for review", async () => {
		const { panel, server, type, notices } = await opened();
		server.failWith(METHOD.ompSessionsSend, "CONFLICT", "omp is not ready");
		type("s");
		type("hello");
		panel.handleInput(ENTER);
		await waitFor(() => panel.flash?.level === "error");
		expect(panel.flash?.text).toBe("steer to omp_3f9a1c2b7d4e failed: omp is not ready");
		expect(panel.prompt?.text).toBe("hello");
		expect(notices.at(-1)?.level).toBe("error");
		panel.handleInput(ESC);
		expect(panel.prompt).toBeUndefined();
		expect(panel.visible).toBe(true);
	});

	test("an unanswered send is an unknown outcome, never success", async () => {
		const { panel, type, methods } = await opened();
		methods.ompSessionsSend = () =>
			Promise.reject(new RequestTimeoutError(METHOD.ompSessionsSend, 30_000));
		type("s");
		type("hello");
		panel.handleInput(ENTER);
		await waitFor(() => panel.flash?.level === "error");
		expect(panel.flash?.text).toBe(
			"steer to omp_3f9a1c2b7d4e failed: no reply within 30s — outcome unknown; refresh before retrying",
		);
		expect(panel.prompt?.text).toBe("hello");
	});

	test("c cancels the running turn; x closes; ended sessions refuse both", async () => {
		const { panel, server, store, type } = await opened();
		type("c");
		await server.waitForRequest(METHOD.ompSessionsCancel);
		await waitFor(() => panel.flash?.text === "cancelled the running turn of omp_3f9a1c2b7d4e");
		type("x");
		await server.waitForRequest(METHOD.ompSessionsClose);
		await waitFor(() => store.get("omp_3f9a1c2b7d4e")?.status === "closed");
		expect(panel.flash?.text).toBe("closed omp_3f9a1c2b7d4e; its omp session stays resumable (d)");
		// The selection follows the session as it re-sorts among the ended ones.
		expect(panel.selected?.id).toBe("omp_3f9a1c2b7d4e");
		server.clearReceived();
		type("c");
		type("s");
		expect(panel.flash?.text).toBe("omp_3f9a1c2b7d4e has ended — press d to find and resume it");
		expect(panel.prompt).toBeUndefined();
		expect(server.requestsFor(METHOD.ompSessionsCancel)).toHaveLength(0);
	});

	test("offline mutations are not sent or queued", async () => {
		const { panel, server, client, type, notices } = await opened();
		client.close();
		server.clearReceived();
		type("x");
		expect(panel.flash).toEqual({
			text: "offline — close not sent; reconnect and retry",
			level: "warning",
		});
		expect(notices.at(-1)?.text).toBe("omp: offline — close not sent; reconnect and retry");
		type("s");
		type("hi");
		panel.handleInput(ENTER);
		await waitFor(
			() => panel.prompt?.sending === false && panel.flash?.text.includes("steer") === true,
		);
		expect(panel.prompt?.text).toBe("hi");
		expect(server.requestsFor(METHOD.ompSessionsClose)).toHaveLength(0);
		expect(server.requestsFor(METHOD.ompSessionsSend)).toHaveLength(0);
		expect(client.queued).toHaveLength(0);
	});

	test("d discovers sessions for the cwd and Enter resumes one there", async () => {
		const { panel, server, store, rendered, type } = await opened();
		type("d");
		await waitFor(() => panel.mode === "discover" && rendered().includes("Port the CLI to Bun"));
		expect(server.requestsFor(METHOD.ompSessionsDiscover)[0]?.params).toEqual({
			cwd: "/work/lemon",
			limit: 30,
		});
		expect(rendered()).toContain("live omp_3f9a1c2b7d4e");
		panel.handleInput(ENTER);
		const request = await server.waitForRequest(METHOD.ompSessionsResume);
		expect(request.params).toEqual({
			ompSessionId: "01a13700-aaaa-7000-8000-00000000000a",
			cwd: "/work/lemon",
		});
		await waitFor(() => panel.mode === "list");
		expect(store.sessions().some((session) => session.title === "Port the CLI to Bun")).toBe(true);
		expect(panel.flash?.text).toMatch(/^resumed Port the CLI to Bun as omp_fake\d+$/);
	});

	test("resuming a session that is already live is refused locally", async () => {
		const { panel, server, type } = await opened();
		type("d");
		await waitFor(() => panel.selectedDiscovered !== undefined);
		type(DOWN);
		panel.handleInput(ENTER);
		expect(panel.flash?.text).toBe(
			"already live as omp_3f9a1c2b7d4e — select it in the list instead",
		);
		expect(server.requestsFor(METHOD.ompSessionsResume)).toHaveLength(0);
		panel.handleInput(ESC);
		expect(panel.mode).toBe("list");
	});

	test("Escape closes the panel and hands focus back", async () => {
		const app = await opened();
		app.panel.handleInput(ESC);
		expect(app.panel.visible).toBe(false);
		expect(app.blurred()).toBe(1);
	});

	test("a daemon without omp methods says so", async () => {
		const { rendered } = await opened({ methods: DEFAULT_METHODS });
		expect(rendered()).toContain("this daemon does not expose the omp.* methods");
	});

	test("omp not installed is shown and blocks resume", async () => {
		const { rendered, panel, server, type } = await opened({ available: false });
		expect(rendered()).toContain("omp is not installed on the daemon host");
		type("d");
		await waitFor(() => panel.selectedDiscovered !== undefined);
		panel.handleInput(ENTER);
		expect(panel.flash?.text).toBe("resume unavailable: omp is not installed on the daemon host");
		expect(server.requestsFor(METHOD.ompSessionsResume)).toHaveLength(0);
	});

	test("the native panel is a card of agent nodes", async () => {
		const { panel } = await opened();
		const node = panel.describe() as {
			k: string;
			c: Array<{ k: string; p?: Record<string, unknown> }>;
		};
		expect(node.k).toBe("card");
		const agents = node.c.filter((child) => child.k === "agent");
		expect(agents).toHaveLength(3);
		expect(agents[0]?.p).toMatchObject({
			name: "Fix the flaky reconnect test",
			agent: "omp",
			status: "running",
			model: "deepseek/deepseek-v4-flash",
			tool: { name: "bash", intent: "Re-running the reconnect suite" },
		});
		expect(agents[0]?.p?.badges).toContainEqual({ text: "selected", tone: "accent" });
		expect(agents[2]?.p?.status).toBe("failed");
	});
});
