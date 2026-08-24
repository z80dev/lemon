/**
 * The three things a prompt submitted during a run can do — hold, steer, stop —
 * driven end to end through the real protocol client against the fake daemon.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { AppShell } from "../../src/app.ts";
import { errorResult, FakeControlPlane } from "../../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import type { AssistantBlock, Block } from "../../src/store/transcript-model.ts";
import { resetBlockIds } from "../../src/store/transcript-model.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal, renderPlain } from "../helpers/memory-terminal.ts";
import { waitFor } from "../helpers/wait.ts";

const SESSION = "tui-modes";

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

interface BootOptions {
	/** Replaces the default `chat.send` handler (for rejection cases). */
	onSend?: (params: { sessionKey: string; prompt: string; queueMode?: string }) => unknown;
}

async function boot(options: BootOptions = {}) {
	const server = await FakeControlPlane.start();
	teardown.push(() => server.stop());
	let runSeq = 0;
	server.onMethod(
		"chat.send",
		options.onSend ??
			((params: { sessionKey: string }) => {
				runSeq += 1;
				return { runId: `run-${runSeq}`, sessionKey: params.sessionKey };
			}),
	);

	const client = new ControlPlaneClient({
		url: server.url,
		socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
	});
	const app = new AppShell({
		url: server.url,
		sessionKey: SESSION,
		version: "test",
		client,
		terminal: new MemoryTerminal(),
		smoothStreaming: false,
	});
	teardown.push(() => app.stop());
	await app.start();
	return { app, server };
}

function sends(server: FakeControlPlane) {
	return server.requestsFor("chat.send").map((frame) => frame.params as Record<string, unknown>);
}

function transcript(app: AppShell): string {
	return renderPlain(app.chatContainer.render(80));
}

function kinds(blocks: readonly Block[]): string[] {
	return blocks.map((block) => block.kind);
}

function complete(server: FakeControlPlane, runId: string, answer = "") {
	server.pushEvent("agent", { type: "completed", runId, sessionKey: SESSION, ok: true, answer });
}

describe("queue mode", () => {
	test("a prompt submitted during a run is held, not sent", async () => {
		const { app, server } = await boot();
		await app.submit("first");
		expect(app.store.focused.busy).toBe(true);

		await app.submit("second");

		// Exactly one prompt reached the daemon.
		expect(sends(server).map((params) => params.prompt)).toEqual(["first"]);
		expect(app.store.queue.items(SESSION).map((item) => item.text)).toEqual(["second"]);
		expect(renderPlain(app.queueContainer.render(80))).toContain("1. second");
		expect(transcript(app)).toContain("queued (1)");
	});

	test("the head of the queue is sent when the run finishes", async () => {
		const { app, server } = await boot();
		await app.submit("first");
		await app.submit("second");
		await app.submit("third");
		expect(app.store.queue.length(SESSION)).toBe(2);

		complete(server, "run-1");
		await waitFor(() => sends(server).length === 2, { what: "the queued prompt to be sent" });
		await waitFor(() => app.store.focused.busy, { what: "the drained prompt to start a run" });

		expect(sends(server)[1]).toEqual({ sessionKey: SESSION, prompt: "second" });
		// One per completion: "third" waits for the run "second" just started.
		expect(app.store.queue.items(SESSION).map((item) => item.text)).toEqual(["third"]);
		expect(app.store.focused.busy).toBe(true);
	});

	test("a queued prompt can be pulled back into the editor and deleted", async () => {
		const { app } = await boot();
		await app.submit("first");
		await app.submit("keep me");
		await app.submit("drop me");

		expect(app.focusQueue()).toBe(true);
		const [first, second] = app.store.queue.items(SESSION);
		app.deleteQueued(second!);
		expect(app.store.queue.items(SESSION).map((item) => item.text)).toEqual(["keep me"]);

		app.editQueued(first!);
		expect(app.editor.getText()).toBe("keep me");
		expect(app.store.queue.length(SESSION)).toBe(0);
		// An emptied queue takes its panel with it.
		expect(app.queueContainer.render(80)).toEqual([]);
	});

	test("focusing an empty queue reports that there was nothing to focus", async () => {
		const { app } = await boot();
		expect(app.focusQueue()).toBe(false);
	});

	test("prompts the protocol client parked while offline show up in the panel", async () => {
		const { app, server } = await boot();
		server.stop();
		await waitFor(() => app.client.state !== "online", { what: "the connection to drop" });

		// Not awaited on purpose: an offline `chat.send` is parked by the protocol
		// client and only settles when the socket comes back.
		void app.submit("typed before the daemon was ready");
		await waitFor(() => app.client.queued.length === 1, { what: "the parked request" });

		const panel = renderPlain(app.queueContainer.render(80));
		expect(panel).toContain("(offline) typed before the daemon was ready");
		// It is the client's to flush, not ours to send: our own queue stays empty.
		expect(app.store.queue.length(SESSION)).toBe(0);
	});
});

describe("steer mode", () => {
	test("steering sends straight into the running turn", async () => {
		const { app, server } = await boot();
		app.store.setSubmissionMode("steer");
		await app.submit("first");
		await app.submit("actually, do it this way");

		expect(sends(server)[1]).toEqual({
			sessionKey: SESSION,
			prompt: "actually, do it this way",
			queueMode: "steer",
		});
		expect(app.store.queue.length(SESSION)).toBe(0);
	});

	test("steering an idle session sends a plain turn instead", async () => {
		const { app, server } = await boot();
		app.store.setSubmissionMode("steer");
		await app.submit("first");
		complete(server, "run-1");
		await waitFor(() => app.store.focused.busy === false, { what: "the run to finish" });

		await app.submit("a new thought");

		// No queueMode at all: the daemon's default is collect, and this is a turn.
		expect(sends(server)[1]).toEqual({ sessionKey: SESSION, prompt: "a new thought" });
		expect(transcript(app)).toContain("the run finished first");
	});

	test("a session that has never run steers silently", async () => {
		const { app, server } = await boot();
		app.store.setSubmissionMode("steer");
		await app.submit("first thing I ever say");

		expect(sends(server)[0]).toEqual({ sessionKey: SESSION, prompt: "first thing I ever say" });
		expect(transcript(app)).not.toContain("the run finished first");
	});

	test("a daemon that refuses to steer leaves the prompt in the queue", async () => {
		const { app } = await boot({
			onSend: (params) => {
				if (params.queueMode === "steer") {
					return errorResult("UNSUPPORTED", "this engine cannot be steered");
				}
				return { runId: "run-1", sessionKey: params.sessionKey };
			},
		});
		app.store.setSubmissionMode("steer");
		await app.submit("first");
		await app.submit("steer me");

		expect(app.store.queue.items(SESSION).map((item) => item.text)).toEqual(["steer me"]);
		const text = transcript(app);
		expect(text).toContain("steer refused");
		expect(text).toContain("this engine cannot be steered");
		// The prompt is still reachable: it is in the panel, editable.
		expect(renderPlain(app.queueContainer.render(80))).toContain("steer me");
	});
});

describe("interrupt mode", () => {
	test("the partial answer is kept, marked, and the new prompt lands under it", async () => {
		const { app, server } = await boot();
		app.store.setSubmissionMode("interrupt");
		await app.submit("write me an essay");
		server.pushEvent("chat", {
			type: "delta",
			runId: "run-1",
			sessionKey: SESSION,
			seq: 1,
			text: "The first half of an essay",
		});
		const session = app.store.focused;
		await waitFor(() => session.bufferFor("run-1").length > 0, { what: "the partial answer" });

		await app.submit("stop, do this instead");

		expect(sends(server)[1]).toEqual({
			sessionKey: SESSION,
			prompt: "stop, do this instead",
			queueMode: "interrupt",
		});
		const interrupted = session.blocks.find(
			(block): block is AssistantBlock => block.kind === "assistant" && block.runId === "run-1",
		);
		expect(interrupted?.status).toBe("aborted");
		// The partial text survives; the marker says why it stops there.
		expect(interrupted?.text).toContain("The first half of an essay");

		const text = transcript(app);
		expect(text).toContain("The first half of an essay");
		expect(text).toContain("[interrupted]");
		// notice(connected), the first prompt, its interrupted answer, then the
		// interrupting prompt — in that order.
		expect(kinds(session.blocks).slice(0, 4)).toEqual(["notice", "user", "assistant", "user"]);
		expect(text.indexOf("[interrupted]")).toBeLessThan(text.indexOf("stop, do this instead"));
	});

	test("a refused interrupt leaves the run alone", async () => {
		const { app } = await boot({
			onSend: (params) => {
				if (params.queueMode === "interrupt") return errorResult("BUSY", "cannot interrupt now");
				return { runId: "run-1", sessionKey: params.sessionKey };
			},
		});
		app.store.setSubmissionMode("interrupt");
		await app.submit("start something");
		await app.submit("never mind");

		const session = app.store.focused;
		// Nothing was marked interrupted: the run is still going.
		expect(session.assistantFor("run-1")?.status).toBe("streaming");
		expect(session.busy).toBe(true);
		expect(app.store.queue.items(SESSION).map((item) => item.text)).toEqual(["never mind"]);
	});

	test("ctrl+c on a busy session marks the run interrupted", async () => {
		const { app, server } = await boot();
		server.respondWith("chat.abort", { aborted: true, runId: "run-1" });
		await app.submit("long job");
		server.pushEvent("chat", {
			type: "delta",
			runId: "run-1",
			sessionKey: SESSION,
			seq: 1,
			text: "partial work",
		});
		const session = app.store.focused;
		await waitFor(() => session.bufferFor("run-1").length > 0, { what: "the partial answer" });

		app.editor.handleInput("\x03");
		await waitFor(() => session.assistantFor("run-1")?.status === "aborted", {
			what: "the run to be sealed as interrupted",
		});
		expect(transcript(app)).toContain("[interrupted]");
	});
});

describe("alt+enter", () => {
	test("cycles the mode for the next submission only", async () => {
		const { app, server } = await boot();
		expect(app.store.submissionMode).toBe("queue");
		await app.submit("first");

		app.editor.handleInput("\x1b\r");
		expect(app.effectiveMode).toBe("steer");
		// The standing default is untouched: this is a one-shot.
		expect(app.store.submissionMode).toBe("queue");
		expect(app.statusData().mode).toBe("steer");

		await app.submit("steered once");
		expect(sends(server)[1]?.queueMode).toBe("steer");

		// Spent. The next prompt goes back to queuing.
		expect(app.effectiveMode).toBe("queue");
		await app.submit("queued now");
		expect(sends(server)).toHaveLength(2);
		expect(app.store.queue.length(SESSION)).toBe(1);
	});

	test("cycling walks every mode and comes back round", async () => {
		const { app } = await boot();
		expect(app.cycleSubmissionMode()).toBe("steer");
		expect(app.cycleSubmissionMode()).toBe("interrupt");
		expect(app.cycleSubmissionMode()).toBe("queue");
	});
});
