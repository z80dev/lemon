/**
 * End-to-end through the real protocol client: a scripted conversation is
 * pushed by the fake control plane, and both the block model and the rendered
 * transcript are asserted against it.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import { AppShell } from "../../src/app.ts";
import { FakeControlPlane } from "../../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import type { AssistantBlock, Block } from "../../src/store/transcript-model.ts";
import { resetBlockIds } from "../../src/store/transcript-model.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal, renderPlain } from "../helpers/memory-terminal.ts";
import { waitFor } from "../helpers/wait.ts";

const SESSION = "tui-it";
const RUN = "run-it-1";
const DELTAS = [
	"# Report\n\n",
	"The first paragraph is complete and frozen.\n\n",
	"The second paragraph is still ",
	"growing as tokens arrive, with an emoji 👩‍👩‍👧‍👦 in it.",
];

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

async function boot() {
	const server = await FakeControlPlane.start();
	teardown.push(() => server.stop());
	server.onMethod("chat.send", (params: { sessionKey: string }) => ({
		runId: RUN,
		sessionKey: params.sessionKey,
	}));

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
	});
	teardown.push(() => app.stop());
	await app.start();
	return { app, server };
}

function transcript(app: AppShell): string {
	return renderPlain(app.chatContainer.render(80));
}

function kinds(blocks: readonly Block[]): string[] {
	return blocks.map((block) => block.kind);
}

describe("scripted conversation", () => {
	test("started -> deltas -> tool_use -> completed builds the expected transcript", async () => {
		const { app, server } = await boot();
		await app.submit("write me a report");

		server.pushEvent("agent", {
			type: "started",
			runId: RUN,
			sessionKey: SESSION,
			engine: "claude",
		});
		for (const [index, text] of DELTAS.entries()) {
			server.pushEvent("chat", {
				type: "delta",
				runId: RUN,
				sessionKey: SESSION,
				seq: index + 1,
				text,
			});
		}
		server.pushEvent("agent", {
			type: "tool_use",
			runId: RUN,
			sessionKey: SESSION,
			phase: "started",
			action: { id: "act-1", kind: "command", title: "bash: ls -la", detail: { args: "ls -la" } },
		});

		const session = app.store.focused;
		await waitFor(() => session.blocks.some((block) => block.kind === "tool"), {
			what: "the tool block",
		});
		expect(session.busy).toBe(true);
		expect(session.activeRunId).toBe(RUN);
		expect(transcript(app)).toContain("bash: ls -la");

		server.pushEvent("agent", {
			type: "tool_use",
			runId: RUN,
			sessionKey: SESSION,
			phase: "completed",
			ok: true,
			message: "12 entries",
			action: { id: "act-1", kind: "command", title: "bash: ls -la", detail: null },
		});
		server.pushEvent("agent", {
			type: "completed",
			runId: RUN,
			sessionKey: SESSION,
			ok: true,
			// Server-truncated answer: must lose to the accumulated deltas.
			answer: DELTAS.join("").slice(0, 40),
			durationMs: 1234,
		});

		await waitFor(() => session.busy === false, { what: "the run to finish" });

		// Block model: notice (connected) + user + assistant + tool.
		expect(kinds(session.blocks)).toEqual(["notice", "user", "assistant", "tool"]);

		const assistant = session.blocks.find(
			(block): block is AssistantBlock => block.kind === "assistant",
		);
		expect(assistant?.status).toBe("done");
		// The accumulated delta buffer is the source of truth for the final text.
		expect(assistant?.text).toBe(DELTAS.join(""));
		expect(session.bufferFor(RUN)).toBe(DELTAS.join(""));

		const tool = session.blocks.find((block) => block.kind === "tool");
		expect(tool).toMatchObject({ actionId: "act-1", phase: "completed", ok: true });

		const text = transcript(app);
		expect(text).toContain("write me a report");
		expect(text).toContain("Report");
		expect(text).toContain("👩‍👩‍👧‍👦");
		expect(text).toContain("✓ bash: ls -la");
		for (const line of app.chatContainer.render(80)) {
			expect(visibleWidth(line)).toBeLessThanOrEqual(80);
		}
	});

	test("replayed deltas after a reconnect do not duplicate text", async () => {
		const { app, server } = await boot();
		await app.submit("hello");
		for (const seq of [1, 2, 2, 1]) {
			server.pushEvent("chat", {
				type: "delta",
				runId: RUN,
				sessionKey: SESSION,
				seq,
				text: seq === 1 ? "first " : "second ",
			});
		}
		const session = app.store.focused;
		await waitFor(() => session.bufferFor(RUN).length > 0, { what: "the delta buffer" });
		expect(session.bufferFor(RUN)).toBe("first second ");
	});

	test("events for another session land in that session, not the focused one", async () => {
		const { app, server } = await boot();
		server.pushEvent("chat", {
			type: "delta",
			runId: "other-run",
			sessionKey: "someone-else",
			seq: 1,
			text: "not mine",
		});
		await waitFor(() => app.store.sessions.has("someone-else"), { what: "the background session" });

		expect(app.store.session("someone-else").bufferFor("other-run")).toBe("not mine");
		expect(app.store.totalUnread()).toBe(1);
		expect(transcript(app)).not.toContain("not mine");
	});

	test("a failed run renders its error and clears busy", async () => {
		const { app, server } = await boot();
		await app.submit("break something");
		server.pushEvent("agent", { type: "started", runId: RUN, sessionKey: SESSION });
		server.pushEvent("chat", {
			type: "delta",
			runId: RUN,
			sessionKey: SESSION,
			seq: 1,
			text: "trying",
		});
		server.pushEvent("agent", {
			type: "completed",
			runId: RUN,
			sessionKey: SESSION,
			ok: false,
			answer: "provider exploded",
		});

		const session = app.store.focused;
		await waitFor(() => session.busy === false, { what: "the failed run to settle" });
		const assistant = session.blocks.find(
			(block): block is AssistantBlock => block.kind === "assistant",
		);
		expect(assistant?.status).toBe("error");
		expect(assistant?.error).toBe("provider exploded");
		expect(transcript(app)).toContain("Error: provider exploded");
	});

	test("a run that fails with no output still shows the failure", async () => {
		const { app, server } = await boot();
		await app.submit("do the impossible");
		server.pushEvent("agent", {
			type: "started",
			runId: RUN,
			sessionKey: SESSION,
			engine: "lemon",
		});
		// What the live daemon sends for a run that dies before producing text.
		server.pushEvent("agent", {
			type: "completed",
			runId: RUN,
			sessionKey: SESSION,
			ok: false,
			answer: "",
			durationMs: 272,
		});

		const session = app.store.focused;
		await waitFor(() => session.busy === false, { what: "the failed run to settle" });
		expect(transcript(app)).toContain("Error: run failed");
	});

	test("the commit seam opens while streaming and closes when the run ends", async () => {
		const { app, server } = await boot();
		await app.submit("stream please");
		server.pushEvent("agent", { type: "started", runId: RUN, sessionKey: SESSION });
		server.pushEvent("chat", {
			type: "delta",
			runId: RUN,
			sessionKey: SESSION,
			seq: 1,
			text: "frozen paragraph\n\nstreaming tail",
		});

		const session = app.store.focused;
		await waitFor(() => session.bufferFor(RUN).length > 0, { what: "the first delta" });
		app.chatContainer.render(80);
		const seam = app.chatContainer.getNativeScrollbackLiveRegionStart();
		expect(seam).toBeGreaterThan(0);

		server.pushEvent("agent", {
			type: "completed",
			runId: RUN,
			sessionKey: SESSION,
			ok: true,
			answer: "",
		});
		await waitFor(() => session.busy === false, { what: "the run to finish" });
		app.chatContainer.render(80);
		expect(app.chatContainer.getNativeScrollbackLiveRegionStart()).toBeUndefined();
	});
});
