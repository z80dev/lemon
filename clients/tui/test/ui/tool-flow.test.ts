/**
 * Tool activity end to end: daemon `tool_use` frames → SessionStore blocks →
 * shelves in the transcript.
 *
 * The interesting behaviour is structural rather than cosmetic — where the
 * shelf boundaries fall, and when the transcript's native-scrollback seam is
 * allowed to close. A shelf re-shapes as it grows (a second tool collapses the
 * first into a single line), so its rows must stay out of immutable terminal
 * history until a barrier seals it.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { AppShell } from "../../src/app.ts";
import { FakeControlPlane } from "../../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import { resetBlockIds } from "../../src/store/transcript-model.ts";
import { accordionSettings } from "../../src/ui/components/accordion.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal, renderPlain } from "../helpers/memory-terminal.ts";
import { unfinalizedBlocks } from "../helpers/transcript.ts";
import { waitFor } from "../helpers/wait.ts";

const SESSION = "tui-tools";
const teardown: Array<() => void> = [];

beforeEach(() => {
	resetBlockIds();
	initTheme({ colorLevel: 3 });
});

afterEach(() => {
	while (teardown.length > 0) teardown.pop()?.();
	accordionSettings.reset();
	resetTheme();
	invalidateThemeAdapters();
});

const ALT_E = "\x1be";
const CTRL_T = "\x14";

async function boot() {
	const server = await FakeControlPlane.start();
	teardown.push(() => server.stop());
	const client = new ControlPlaneClient({
		url: server.url,
		socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
	});
	const terminal = new MemoryTerminal();
	const app = new AppShell({
		url: server.url,
		sessionKey: SESSION,
		version: "test",
		client,
		terminal,
	});
	teardown.push(() => app.stop());
	await app.start();
	return { app, server, terminal };
}

interface ToolFrame {
	id: string;
	kind?: string;
	title: string;
	detail?: Record<string, unknown> | null;
	phase: string;
	ok?: boolean;
	message?: string;
}

function tool(server: FakeControlPlane, frame: ToolFrame): void {
	server.pushEvent("agent", {
		type: "tool_use",
		runId: "run-1",
		sessionKey: SESSION,
		action: {
			id: frame.id,
			kind: frame.kind ?? "tool",
			title: frame.title,
			detail: frame.detail ?? null,
		},
		phase: frame.phase,
		ok: frame.ok ?? null,
		message: frame.message ?? null,
	});
}

function transcript(app: AppShell, width = 100): string {
	return renderPlain(app.chatContainer.render(width));
}

function toolBlocks(app: AppShell) {
	return app.store.focused.blocks.filter((block) => block.kind === "tool");
}

describe("tool cards in the transcript", () => {
	test("a running tool renders a card and keeps the commit seam open", async () => {
		const { app, server } = await boot();
		tool(server, {
			id: "t1",
			kind: "command",
			title: "`ls -la`",
			detail: { name: "bash", args: { command: "ls -la" } },
			phase: "started",
		});
		await waitFor(() => toolBlocks(app).length === 1, { what: "the tool block" });
		await waitFor(() => transcript(app).includes("`ls -la`"), { what: "the card" });

		app.chatContainer.render(100);
		// Still mutating: nothing below it may commit to native scrollback.
		expect(unfinalizedBlocks(app.chatContainer).length).toBeGreaterThan(0);
	});

	test("the completed result replaces the card body in place", async () => {
		const { app, server } = await boot();
		const detail = { name: "bash", args: { command: "ls -la" } };
		tool(server, { id: "t1", kind: "command", title: "`ls -la`", detail, phase: "started" });
		await waitFor(() => toolBlocks(app).length === 1, { what: "the tool block" });

		tool(server, {
			id: "t1",
			kind: "command",
			title: "`ls -la`",
			detail: { ...detail, result: "biome.json\nbun.lock", result_meta: { exit_code: 0 } },
			phase: "completed",
			ok: true,
		});
		await waitFor(() => transcript(app).includes("biome.json"), { what: "the result" });

		// One block, one card — the phases upsert rather than stack.
		expect(toolBlocks(app).length).toBe(1);
		expect(transcript(app)).toContain("✓ `ls -la`");
	});

	test("a failed tool renders the error glyph and the daemon's message", async () => {
		const { app, server } = await boot();
		tool(server, {
			id: "t1",
			kind: "command",
			title: "`false`",
			detail: { name: "bash", args: { command: "false" }, result_meta: { exit_code: 1 } },
			phase: "completed",
			ok: false,
			message: "command exited with status 1",
		});
		await waitFor(() => transcript(app).includes("✗ `false`"), { what: "the failed card" });
		expect(transcript(app)).toContain("command exited with status 1");
	});
});

describe("reasoning at the end of a run", () => {
	test("a run that ends mid-thought still closes the commit seam", async () => {
		const { app, server } = await boot();
		server.pushEvent("agent", { type: "started", runId: "run-1", sessionKey: SESSION });
		tool(server, {
			id: "r1",
			kind: "reasoning",
			title: "reasoning",
			detail: { reasoning: { text: "half a thought", source: "lemon_reasoning" } },
			phase: "updated",
		});
		await waitFor(() => transcript(app).includes("half a thought"), { what: "the thought" });

		server.pushEvent("agent", {
			type: "completed",
			runId: "run-1",
			sessionKey: SESSION,
			ok: false,
			answer: "",
		});
		await waitFor(
			() => {
				app.chatContainer.render(100);
				return unfinalizedBlocks(app.chatContainer).length === 0;
			},
			{ what: "the seam to close" },
		);
		expect(transcript(app)).not.toContain("thinking…");
	});
});

describe("shelf merging", () => {
	test("consecutive tools share one shelf and merge to a line each", async () => {
		const { app, server } = await boot();
		for (const [id, title] of [
			["t1", "read: `a.ts`"],
			["t2", "read: `b.ts`"],
			["t3", "read: `c.ts`"],
		]) {
			tool(server, {
				id: id as string,
				title: title as string,
				detail: { name: "read", args: { path: `${id}.ts` }, result: "contents" },
				phase: "completed",
				ok: true,
			});
		}
		await waitFor(() => toolBlocks(app).length === 3, { what: "three tool blocks" });
		await waitFor(() => transcript(app).includes("read: `c.ts`"), { what: "the third line" });

		// Three tool blocks, one transcript child, three rendered rows.
		const text = transcript(app);
		expect(text).toContain("read: `a.ts`");
		expect(text).toContain("read: `b.ts`");
		expect(text.split("\n").filter((line) => line.includes("read: `")).length).toBe(3);
	});

	test("a non-tool block is a barrier: the next tool opens a fresh shelf", async () => {
		const { app, server } = await boot();
		tool(server, {
			id: "t1",
			title: "read: `a.ts`",
			detail: { name: "read", args: { path: "a.ts" }, result: "contents" },
			phase: "completed",
			ok: true,
		});
		await waitFor(() => toolBlocks(app).length === 1, { what: "the first tool" });

		app.events.notice("something happened");
		tool(server, {
			id: "t2",
			title: "read: `b.ts`",
			detail: { name: "read", args: { path: "b.ts" }, result: "contents" },
			phase: "completed",
			ok: true,
		});
		await waitFor(() => toolBlocks(app).length === 2, { what: "the second tool" });
		await waitFor(() => transcript(app).includes("read: `b.ts`"), { what: "the second card" });

		const lines = transcript(app).split("\n");
		const first = lines.findIndex((line) => line.includes("read: `a.ts`"));
		const notice = lines.findIndex((line) => line.includes("something happened"));
		const second = lines.findIndex((line) => line.includes("read: `b.ts`"));
		expect(first).toBeGreaterThanOrEqual(0);
		expect(notice).toBeGreaterThan(first);
		expect(second).toBeGreaterThan(notice);
		// Each shelf holds one tool, so both keep their full cards.
		expect(transcript(app)).toContain("contents");
	});

	test("the run completing seals the shelf and closes the commit seam", async () => {
		const { app, server } = await boot();
		server.pushEvent("agent", { type: "started", runId: "run-1", sessionKey: SESSION });
		tool(server, {
			id: "t1",
			title: "read: `a.ts`",
			detail: { name: "read", args: { path: "a.ts" }, result: "contents" },
			phase: "completed",
			ok: true,
		});
		await waitFor(() => toolBlocks(app).length === 1, { what: "the tool block" });

		server.pushEvent("agent", {
			type: "completed",
			runId: "run-1",
			sessionKey: SESSION,
			ok: true,
			answer: "done",
		});
		await waitFor(() => app.store.focused.busy === false, { what: "the run to settle" });
		await waitFor(
			() => {
				app.chatContainer.render(100);
				return unfinalizedBlocks(app.chatContainer).length === 0;
			},
			{ what: "the seam to close" },
		);
	});

	test("rebuilding the session reproduces the same shelves", async () => {
		const { app, server } = await boot();
		app.events.addUserBlock("go");
		for (const id of ["t1", "t2"]) {
			tool(server, {
				id,
				title: `read: \`${id}.ts\``,
				detail: { name: "read", args: { path: `${id}.ts` }, result: "contents" },
				phase: "completed",
				ok: true,
			});
		}
		await waitFor(() => toolBlocks(app).length === 2, { what: "both tools" });
		await waitFor(() => transcript(app).includes("read: `t2.ts`"), { what: "the second line" });
		const before = transcript(app);

		app.events.rebuildFocused();
		expect(transcript(app)).toBe(before);
	});
});

describe("replayed frames", () => {
	test("a started frame redelivered after completed cannot reopen the commit seam", async () => {
		const { app, server } = await boot();
		const detail = { name: "bash", args: { command: "ls -la" } };
		server.pushEvent("agent", { type: "started", runId: "run-1", sessionKey: SESSION });
		tool(server, { id: "t1", kind: "command", title: "`ls -la`", detail, phase: "started" });
		await waitFor(() => toolBlocks(app).length === 1, { what: "the tool block" });
		tool(server, {
			id: "t1",
			kind: "command",
			title: "`ls -la`",
			detail: { ...detail, result: "biome.json", result_meta: { exit_code: 0 } },
			phase: "completed",
			ok: true,
		});
		server.pushEvent("agent", {
			type: "completed",
			runId: "run-1",
			sessionKey: SESSION,
			ok: true,
			answer: "done",
		});
		await waitFor(
			() => {
				app.chatContainer.render(100);
				return unfinalizedBlocks(app.chatContainer).length === 0;
			},
			{ what: "the seam to close" },
		);
		const sealed = transcript(app);

		// A reconnect replays the opening frames. Nothing may move: the sealed rows
		// may already be in native scrollback, where they cannot be rewritten.
		tool(server, { id: "t1", kind: "command", title: "`ls -la`", detail, phase: "started" });
		tool(server, { id: "t1", kind: "command", title: "`ls -la`", detail, phase: "updated" });
		await waitFor(() => app.store.focused.byActionId.get("t1")?.phase === "completed", {
			what: "the phase to stay completed",
		});

		expect(transcript(app)).toBe(sealed);
		expect(transcript(app)).toContain("biome.json");
		app.chatContainer.render(100);
		expect(unfinalizedBlocks(app.chatContainer)).toHaveLength(0);
	});
});

describe("action kinds", () => {
	test("reasoning is its own collapsed transcript block, not a tool card", async () => {
		const { app, server } = await boot();
		tool(server, {
			id: "r1",
			kind: "reasoning",
			title: "weighing the options…",
			detail: {
				reasoning: { text: "weighing the options…\nfirst option\nsecond option", source: "lemon" },
			},
			phase: "completed",
			ok: true,
		});
		await waitFor(() => transcript(app).includes("weighing the options"), { what: "the thought" });
		expect(toolBlocks(app).length).toBe(0);
		expect(app.store.focused.blocks.map((block) => block.kind)).toContain("reasoning");
		const text = transcript(app);
		expect(text).toContain("✻ thinking");
		// Collapsed: the body's extra lines are behind the "+N more lines" hint.
		expect(text).toContain("+2 more lines");
		expect(text).not.toContain("second option");
	});

	test("streamed reasoning updates one block in place until it completes", async () => {
		const { app, server } = await boot();
		const frame = (text: string, phase: string) =>
			tool(server, {
				id: "r1",
				kind: "reasoning",
				title: "reasoning",
				detail: { reasoning: { text, source: "lemon_reasoning" } },
				phase,
			});
		frame("", "started");
		frame("checking the shelf", "updated");
		await waitFor(() => transcript(app).includes("checking the shelf"), { what: "the update" });
		expect(transcript(app)).toContain("thinking…");
		frame("checking the shelf, then the seam", "completed");
		await waitFor(() => transcript(app).includes("then the seam"), { what: "the final text" });
		expect(transcript(app)).not.toContain("thinking…");
		expect(app.store.focused.blocks.filter((block) => block.kind === "reasoning").length).toBe(1);
	});

	test("subagents get their own glyph", async () => {
		const { app, server } = await boot();
		tool(server, {
			id: "s1",
			kind: "subagent",
			title: "task: audit",
			detail: { name: "task", args: { description: "audit" }, result: "audit done" },
			phase: "completed",
			ok: true,
		});
		await waitFor(() => transcript(app).includes("task: audit"), { what: "the subagent" });
		expect(transcript(app)).toContain("◈ task: audit");
	});

	test("an unknown tool renders a generic card rather than nothing", async () => {
		const { app, server } = await boot();
		tool(server, {
			id: "m1",
			title: "custom_search",
			detail: { name: "custom_search", args: { query: "x" }, result: "3 sessions matched" },
			phase: "completed",
			ok: true,
		});
		await waitFor(() => transcript(app).includes("custom_search"), { what: "the card" });
		expect(transcript(app)).toContain("3 sessions matched");
	});
});

describe("expand/collapse keys", () => {
	test("alt+e expands the latest reasoning block and collapses it again", async () => {
		const { app, server, terminal } = await boot();
		tool(server, {
			id: "r1",
			kind: "reasoning",
			title: "weighing",
			detail: { reasoning: { text: "weighing\nfirst option\nsecond option", source: "lemon" } },
			phase: "completed",
			ok: true,
		});
		await waitFor(() => transcript(app).includes("weighing"), { what: "the thought" });
		expect(transcript(app)).not.toContain("second option");

		terminal.sendInput(ALT_E);
		await waitFor(() => transcript(app).includes("second option"), {
			what: "the expanded thought",
		});

		terminal.sendInput(ALT_E);
		await waitFor(() => !transcript(app).includes("second option"), { what: "the collapse" });
	});

	test("alt+e opens the latest merged shelf line into a full card", async () => {
		const { app, server, terminal } = await boot();
		for (const [id, command, output] of [
			["t1", "ls", "biome.json"],
			["t2", "pwd", "/home/z80/dev/lemon"],
		]) {
			tool(server, {
				id,
				kind: "command",
				title: `\`${command}\``,
				detail: { name: "bash", args: { command }, result: output, details: { exit_code: 0 } },
				phase: "completed",
				ok: true,
			});
		}
		await waitFor(() => toolBlocks(app).length === 2, { what: "both tools" });
		// Two finished tools merge into one line each: the output is not shown.
		await waitFor(() => transcript(app).includes("`pwd`"), { what: "the shelf" });
		const merged = transcript(app).split("\n").length;

		terminal.sendInput(ALT_E);
		await waitFor(() => transcript(app).split("\n").length > merged, { what: "the open card" });
		expect(transcript(app)).toContain("/home/z80/dev/lemon");
	});

	test("ctrl+t cycles detail for cards already on screen", async () => {
		const { app, server, terminal } = await boot();
		tool(server, {
			id: "t1",
			kind: "command",
			title: "`ls`",
			detail: {
				name: "bash",
				args: { command: "ls" },
				result: "biome.json\nbun.lock\nsrc",
				details: { exit_code: 0 },
			},
			phase: "completed",
			ok: true,
		});
		await waitFor(() => transcript(app).includes("bun.lock"), { what: "the expanded card" });

		// default → collapsed: the card folds to its summary line.
		terminal.sendInput(CTRL_T);
		await waitFor(() => !transcript(app).includes("bun.lock"), { what: "the collapse" });
		// collapsed → expanded.
		terminal.sendInput(CTRL_T);
		await waitFor(() => transcript(app).includes("bun.lock"), { what: "the expansion" });
		// expanded → default; reset for the other tests either way.
		terminal.sendInput(CTRL_T);
	});
});
