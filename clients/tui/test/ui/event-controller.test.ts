/**
 * Regressions for the ordering and lifecycle defects the render-contract audit
 * found: a completion for one run must not disturb another run's reveal, a
 * rebuilt session must not report a live commit seam, and out-of-order
 * `completed`/delta frames must not lose text.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { AppShell } from "../../src/app.ts";
import { FakeControlPlane } from "../../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import type { AssistantBlock } from "../../src/store/transcript-model.ts";
import { resetBlockIds } from "../../src/store/transcript-model.ts";
import { accordionSettings } from "../../src/ui/components/accordion.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal, renderPlain } from "../helpers/memory-terminal.ts";
import { runText, unfinalizedBlocks } from "../helpers/transcript.ts";
import { waitFor } from "../helpers/wait.ts";

const SESSION = "tui-ec";
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

function delta(server: FakeControlPlane, runId: string, seq: number, text: string): void {
	server.pushEvent("chat", { type: "delta", runId, sessionKey: SESSION, seq, text });
}

function assistantBlocks(app: AppShell): AssistantBlock[] {
	return app.store.focused.blocks.filter(
		(block): block is AssistantBlock => block.kind === "assistant",
	);
}

function transcript(app: AppShell): string {
	return renderPlain(app.chatContainer.render(80));
}

describe("authoritative cancellation", () => {
	test.each([false, true])(
		"renders interrupted even before an abort reply (partial=%s)",
		async (partial) => {
			const { app, server } = await boot();
			if (partial) {
				server.pushEvent("agent", { type: "started", runId: "cancelled", sessionKey: SESSION });
				delta(server, "cancelled", 1, "Kept partial answer.");
				await waitFor(() => runText(app.store.focused, "cancelled").length > 0);
			}
			server.pushEvent("agent", {
				type: "completed",
				runId: "cancelled",
				sessionKey: SESSION,
				ok: false,
				cancelled: true,
				error: "Run cancelled",
				answer: "",
			});
			await waitFor(() => app.store.focused.assistantFor("cancelled")?.status === "aborted");
			const rendered = transcript(app);
			expect(rendered).toContain("[interrupted]");
			if (partial) expect(rendered).toContain("Kept partial answer.");
			expect(rendered).not.toContain("Error:");
			expect(app.store.focused.busy).toBe(false);
		},
	);

	test.each([
		"Provider unavailable",
		{ code: "provider_failure", message: "Provider unavailable" },
	])("preserves real failure receipts instead of treating them as cancellation", async (error) => {
		const { app, server } = await boot();
		server.pushEvent("agent", {
			type: "completed",
			runId: "failed",
			sessionKey: SESSION,
			ok: false,
			cancelled: false,
			error,
			answer: "",
		});
		await waitFor(() => app.store.focused.assistantFor("failed")?.status === "error");
		expect(transcript(app)).toContain("Provider unavailable");
		expect(transcript(app)).not.toContain("[interrupted]");
		expect(transcript(app)).not.toContain("[object Object]");
	});
});

describe("completed for another run", () => {
	test("does not flush or stop the reveal driving the live run", async () => {
		const { app, server } = await boot();
		const session = app.store.focused;

		// Run A finished earlier; run B is streaming now.
		server.pushEvent("agent", { type: "started", runId: "run-a", sessionKey: SESSION });
		delta(server, "run-a", 1, "first answer");
		await waitFor(() => runText(session, "run-a").length > 0, { what: "run A's delta" });

		// Long enough that the reveal is provably still mid-flight when run A's
		// stale completion lands (a few hundred ms of frames at 30fps).
		const longAnswer = `${"the second answer runs on and on and on, ".repeat(6)}still running`;
		server.pushEvent("agent", { type: "started", runId: "run-b", sessionKey: SESSION });
		delta(server, "run-b", 1, longAnswer);
		await waitFor(() => runText(session, "run-b").length > 0, { what: "run B's delta" });

		// A stale completion for run A lands while run B streams.
		server.pushEvent("agent", {
			type: "completed",
			runId: "run-a",
			sessionKey: SESSION,
			ok: true,
			answer: "first answer",
		});
		await waitFor(() => session.assistantFor("run-a")?.status === "done", {
			what: "run A to seal",
		});

		// Run B must still be live, and its reveal must still be mid-flight: the
		// bug flushed it to the full target and stopped it the moment run A's
		// completion arrived.
		expect(session.assistantFor("run-b")?.status).toBe("streaming");
		expect(transcript(app)).not.toContain("still running");
		// …and it must keep revealing on its own afterwards.
		await waitFor(() => transcript(app).includes("still running"), {
			what: "run B's reveal to complete",
		});
		expect(session.busy).toBe(true);
	});
});

describe("rebuildFocused", () => {
	test("restores finished blocks sealed, leaving no live commit seam", async () => {
		const { app, server } = await boot();
		const session = app.store.focused;

		server.pushEvent("agent", { type: "started", runId: "run-1", sessionKey: SESSION });
		delta(server, "run-1", 1, "a completed reply");
		server.pushEvent("agent", {
			type: "completed",
			runId: "run-1",
			sessionKey: SESSION,
			ok: false,
			answer: "provider exploded",
		});
		await waitFor(() => session.assistantFor("run-1")?.status === "error", {
			what: "the run to seal",
		});

		app.events.rebuildFocused();
		const text = renderPlain(app.chatContainer.render(80));
		expect(text).toContain("a completed reply");
		expect(text).toContain("Error: provider exploded");
		// A sealed block must not reopen the native-scrollback seam.
		expect(unfinalizedBlocks(app.chatContainer)).toHaveLength(0);
	});

	test("restores an aborted block with its interrupted marker", async () => {
		const { app, server } = await boot();
		const session = app.store.focused;

		server.pushEvent("agent", { type: "started", runId: "run-1", sessionKey: SESSION });
		delta(server, "run-1", 1, "half a thou");
		await waitFor(() => runText(session, "run-1").length > 0, { what: "the delta" });
		app.events.markInterrupted("run-1");

		app.events.rebuildFocused();
		const text = renderPlain(app.chatContainer.render(80));
		expect(text).toContain("half a thou");
		expect(text).toContain("[interrupted]");
		expect(unfinalizedBlocks(app.chatContainer)).toHaveLength(0);
		// The marker lives in the component, never in the stored block text.
		expect(session.assistantFor("run-1")?.text).toBe("half a thou");
	});
});

describe("out-of-order run frames", () => {
	test("a delta arriving after completed amends the sealed block", async () => {
		const { app, server } = await boot();
		const session = app.store.focused;

		server.pushEvent("agent", { type: "started", runId: "run-1", sessionKey: SESSION });
		delta(server, "run-1", 1, "the answer is ");
		await waitFor(() => runText(session, "run-1").length > 0, { what: "the first delta" });
		server.pushEvent("agent", {
			type: "completed",
			runId: "run-1",
			sessionKey: SESSION,
			ok: true,
			answer: "the answer is",
		});
		await waitFor(() => session.busy === false, { what: "the run to settle" });

		delta(server, "run-1", 2, "forty-two");
		await waitFor(() => transcript(app).includes("forty-two"), { what: "the amended text" });

		expect(session.assistantFor("run-1")?.text).toBe("the answer is forty-two");
		// Amending must not reopen the seam on a block that is already history.
		app.chatContainer.render(80);
		expect(unfinalizedBlocks(app.chatContainer)).toHaveLength(0);
	});

	test("completed arriving before started still shows the answer", async () => {
		const { app, server } = await boot();
		const session = app.store.focused;

		server.pushEvent("agent", {
			type: "completed",
			runId: "run-1",
			sessionKey: SESSION,
			ok: true,
			answer: "an answer nobody announced",
		});
		await waitFor(() => assistantBlocks(app).length > 0, { what: "the recovered block" });

		expect(session.assistantFor("run-1")?.text).toBe("an answer nobody announced");
		await waitFor(() => transcript(app).includes("an answer nobody announced"), {
			what: "the answer to render",
		});
		expect(unfinalizedBlocks(app.chatContainer)).toHaveLength(0);
	});
});

test("tool boundaries seal each assistant segment before later text reaches the transcript", async () => {
	const { app, server } = await boot();
	server.pushEvent("agent", { type: "started", runId: "run-order", sessionKey: SESSION });
	delta(server, "run-order", 1, "BEFORE_TOOL");
	server.pushEvent("agent", {
		type: "tool_use",
		runId: "run-order",
		sessionKey: SESSION,
		phase: "completed",
		ok: true,
		action: {
			id: "read-order",
			kind: "tool",
			title: "READ_MARKER",
			detail: { name: "read", result: "contents" },
		},
	});
	delta(server, "run-order", 2, "AFTER_TOOL");
	server.pushEvent("agent", {
		type: "completed",
		runId: "run-order",
		sessionKey: SESSION,
		ok: true,
		answer: "BEFORE_TOOLAFTER_TOOL",
	});
	await waitFor(() => app.store.focused.assistantFor("run-order")?.status === "done", {
		what: "ordered completion",
	});
	const text = transcript(app);
	expect(text.indexOf("BEFORE_TOOL")).toBeLessThan(text.indexOf("READ_MARKER"));
	expect(text.indexOf("READ_MARKER")).toBeLessThan(text.indexOf("AFTER_TOOL"));
	expect(text.match(/BEFORE_TOOL/g)).toHaveLength(1);
	expect(text.match(/AFTER_TOOL/g)).toHaveLength(1);
	expect(assistantBlocks(app).filter((block) => block.runId === "run-order")).toHaveLength(2);
});

test("the first global output toggle expands default-collapsed cards", async () => {
	const { app } = await boot();
	accordionSettings.setOverride(undefined);
	try {
		expect(app.events.toggleToolOutputs()).toBe("expanded");
		expect(app.events.toggleToolOutputs()).toBe("collapsed");
	} finally {
		accordionSettings.setOverride(undefined);
	}
});
