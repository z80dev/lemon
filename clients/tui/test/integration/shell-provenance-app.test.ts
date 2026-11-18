/**
 * Shell escapes run only after the user confirms the exact command text.
 *
 * Driven through the real AppShell and the real shell, asserting on marker
 * files and on what reached `chat.send`. Two layers are covered: text that did
 * not come from the keyboard is escaped so it never asks (pastes, templates,
 * skills, restored items, delegated sends), and every path that can still
 * produce live syntax — completions, native edits, joined pastes, markup
 * removal, history — stops at the confirmation, runs nothing on cancel, and
 * runs exactly the displayed command on Run.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AppShell } from "../../src/app.ts";
import { pickString } from "../../src/commands/format.ts";
import { FakeControlPlane } from "../../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal, renderPlain } from "../helpers/memory-terminal.ts";
import { waitFor } from "../helpers/wait.ts";

const CTRL_P = "\x10";
const ESC = "\x1b";
const DOWN = "\x1b[B";
const UP = "\x1b[A";
const paste = (text: string) => `\x1b[200~${text}\x1b[201~`;

const teardown: Array<() => void> = [];
let project: string;

beforeEach(() => {
	initTheme({ colorLevel: 3 });
	project = mkdtempSync(join(tmpdir(), "lemon-tui-shell-provenance-"));
	mkdirSync(join(project, ".git"));
	teardown.push(() => rmSync(project, { recursive: true, force: true }));
});

afterEach(() => {
	while (teardown.length > 0) teardown.pop()?.();
	resetTheme();
	invalidateThemeAdapters();
});

async function bootApp() {
	const home = mkdtempSync(join(tmpdir(), "lemon-tui-shell-provenance-home-"));
	teardown.push(() => rmSync(home, { recursive: true, force: true }));
	const server = await FakeControlPlane.start({
		methods: [
			"chat.send",
			"chat.abort",
			"chat.history",
			"models.list",
			"sessions.patch",
			"status",
			"health",
		],
	});
	teardown.push(() => server.stop());
	server.onMethod("chat.send", (params: { sessionKey: string }) => ({
		runId: "run-1",
		sessionKey: params.sessionKey,
	}));
	server.respondWith("chat.history", { messages: [] });
	server.respondWith("health", { status: "ok" });
	server.respondWith("sessions.patch", { success: true });
	server.respondWith("models.list", {
		models: [{ id: "claude-sonnet-4", provider: "anthropic", contextWindow: 200_000 }],
	});
	server.respondWith("status", { server: { version: "fake-0.0.0" }, runs: { active: 0 } });
	const terminal = new MemoryTerminal();
	const client = new ControlPlaneClient({
		url: server.url,
		socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
	});
	const app = new AppShell({
		url: server.url,
		sessionKey: "tui-shell-provenance",
		version: "test",
		client,
		terminal,
		cwd: project,
		resources: { home, env: {} },
		readBranch: async () => "main",
	});
	teardown.push(() => app.stop());
	await app.start();
	return { app, server, terminal };
}

function prompts(server: FakeControlPlane): Array<string | undefined> {
	return server.requestsFor("chat.send").map((request) => pickString(request.params, "prompt"));
}

function marker(name: string): string {
	return join(project, name);
}

function type(terminal: MemoryTerminal, text: string): void {
	for (const key of text) terminal.sendInput(key);
}

async function sent(server: FakeControlPlane, count = 1): Promise<Array<string | undefined>> {
	await waitFor(() => prompts(server).length >= count, { what: "chat.send" });
	return prompts(server);
}

/** The overlay as the terminal draws it: at the terminal's own width. */
function overlayText(app: AppShell): string {
	return renderPlain(app.selectors.current?.render(app.tui.terminal.columns) ?? []);
}

/** The open shell confirmation's text, once it is up. */
async function confirmation(app: AppShell): Promise<string> {
	await waitFor(() => /Run (this shell command|these shell commands)/.test(overlayText(app)), {
		what: "shell confirmation",
	});
	return overlayText(app);
}

/** Esc on the confirmation: nothing runs, nothing is sent, the draft returns. */
async function cancelAndExpectDraft(app: AppShell, terminal: MemoryTerminal, draft: string) {
	terminal.sendInput(ESC);
	await waitFor(() => !app.selectors.isOpen && app.editor.getExpandedText() === draft, {
		what: "draft restored after declining",
	});
}

describe("non-typed text is escaped and never asks", () => {
	test("a bracketed paste containing {!cmd} is sent literally and runs nothing", async () => {
		const { app, server, terminal } = await bootApp();
		terminal.sendInput(paste("please look at {!touch pasted-marker}"));
		terminal.sendInput("\r");
		expect(await sent(server)).toEqual(["please look at {!touch pasted-marker}"]);
		expect(app.selectors.isOpen).toBe(false);
		expect(existsSync(marker("pasted-marker"))).toBe(false);
	});

	test("pasted JSX `{!loading && <Spinner/>}` reaches the model unchanged", async () => {
		const { app, server, terminal } = await bootApp();
		const jsx = "return <div>{!loading && <Spinner/>}</div>;";
		terminal.sendInput(paste(jsx));
		terminal.sendInput("\r");
		expect(await sent(server)).toEqual([jsx]);
		expect(renderPlain(app.chatContainer.render(100))).not.toContain("$ loading");
	});

	test("a large paste collapsed to a marker does not run its spans", async () => {
		const { server, terminal } = await bootApp();
		const lines = Array.from({ length: 14 }, (_, index) => `line ${index}`);
		lines[7] = "{!touch large-paste-marker}";
		terminal.sendInput(paste(lines.join("\n")));
		terminal.sendInput("\r");
		expect(await sent(server)).toEqual([lines.join("\n")]);
		expect(existsSync(marker("large-paste-marker"))).toBe(false);
	});

	test("a paste starting with ! is a prompt, not an interactive command", async () => {
		const { server, terminal } = await bootApp();
		terminal.sendInput(paste("!touch bang-paste-marker"));
		terminal.sendInput("\r");
		expect(await sent(server)).toEqual(["!touch bang-paste-marker"]);
		expect(existsSync(marker("bang-paste-marker"))).toBe(false);
	});

	test("control bytes the editor strips cannot join `{` and `!` in a paste", async () => {
		const { server, terminal } = await bootApp();
		terminal.sendInput(paste("x {\x01!touch control-marker}"));
		terminal.sendInput("\r");
		expect(await sent(server)).toEqual(["x {!touch control-marker}"]);
		expect(existsSync(marker("control-marker"))).toBe(false);
	});

	test("a delegated native send does not run shell spans", async () => {
		const { app, server } = await bootApp();
		app.editor.handleNativeEvent({ type: "send", key: "", text: "{!touch native-marker}" });
		expect(await sent(server)).toEqual(["{!touch native-marker}"]);
		expect(existsSync(marker("native-marker"))).toBe(false);
	});

	test("a queued literal span pulled back into the editor stays literal", async () => {
		const { app, server, terminal } = await bootApp();
		app.store.focused.busy = true;
		terminal.sendInput(paste("{!touch queue-marker}"));
		terminal.sendInput("\r");
		await waitFor(() => app.store.queue.length(app.sessionKey) === 1, { what: "queued" });
		app.store.focused.busy = false;
		app.editQueued(app.store.queue.items(app.sessionKey)[0]!);
		terminal.sendInput("\r");
		expect(await sent(server)).toEqual(["{!touch queue-marker}"]);
		expect(existsSync(marker("queue-marker"))).toBe(false);
	});
});

describe("repo-controlled palette inserts are escaped", () => {
	async function insertTemplate(app: AppShell, terminal: MemoryTerminal) {
		terminal.sendInput(CTRL_P);
		await waitFor(() => app.selectors.isOpen, { what: "palette" });
		type(terminal, "evilreview");
		await waitFor(() => overlayText(app).includes("prompt:evilreview"), {
			what: "template entry",
		});
		terminal.sendInput("\r");
		await waitFor(() => app.editor.getExpandedText().includes("template-marker"), {
			what: "inserted template",
		});
	}

	test.each([
		[".lemon/prompts", "Review this {!touch template-marker} please", undefined],
		[".claude/prompts", "Review this {!touch template-marker} please", undefined],
		[".lemon/prompts", "!touch template-marker", undefined],
		[".lemon/prompts", "Review {\x01!touch template-marker}", "Review {!touch template-marker}"],
		[".lemon/prompts", "\x01!touch template-marker", "!touch template-marker"],
	])("a %s template %j runs nothing", async (dir, body, expected) => {
		mkdirSync(join(project, dir), { recursive: true });
		writeFileSync(join(project, dir, "evilreview.md"), body);
		const { app, server, terminal } = await bootApp();
		await insertTemplate(app, terminal);
		terminal.sendInput("\r");
		expect(await sent(server)).toEqual([expected ?? body]);
		expect(existsSync(marker("template-marker"))).toBe(false);
	});

	test("a skill whose name carries {!cmd} runs nothing", async () => {
		mkdirSync(join(project, ".lemon/skill/{!touch skill-marker}"), { recursive: true });
		writeFileSync(join(project, ".lemon/skill/{!touch skill-marker}/SKILL.md"), "Do things");
		const { app, server, terminal } = await bootApp();
		terminal.sendInput(CTRL_P);
		await waitFor(() => app.selectors.isOpen, { what: "palette" });
		type(terminal, "skill-marker");
		await waitFor(() => overlayText(app).includes("skill:{!touch skill-marker}"), {
			what: "skill entry",
		});
		terminal.sendInput("\r");
		await waitFor(() => app.editor.getExpandedText().includes("read_skill"), {
			what: "inserted skill",
		});
		type(terminal, "go");
		terminal.sendInput("\r");
		const [prompt] = await sent(server);
		expect(prompt).toContain('"{!touch skill-marker}"');
		expect(existsSync(marker("skill-marker"))).toBe(false);
	});
});

describe("every path to live syntax stops at the confirmation", () => {
	test("a file completion carrying {!cmd} asks, and cancel runs nothing", async () => {
		writeFileSync(join(project, "review{!touch completion-marker}.md"), "x");
		const { app, server, terminal } = await bootApp();
		type(terminal, "see @revi");
		await waitFor(() => app.editor.isShowingAutocomplete(), { what: "file completion" });
		terminal.sendInput("\t");
		await waitFor(() => app.editor.getText().includes("completion-marker"), {
			what: "completed file name",
		});
		// The editor trims what it submits, and that is what a declined submit restores.
		const draft = app.editor.getExpandedText().trim();
		terminal.sendInput("\r");
		expect(await confirmation(app)).toContain("$ touch completion-marker");
		expect(existsSync(marker("completion-marker"))).toBe(false);
		await cancelAndExpectDraft(app, terminal, draft);
		expect(existsSync(marker("completion-marker"))).toBe(false);
		expect(prompts(server)).toEqual([]);
	});

	test("a model mention removed at submit cannot expose a pasted bang", async () => {
		const { app, server, terminal } = await bootApp();
		const draft = "^anthropic:claude-sonnet-4 !touch mention-marker";
		terminal.sendInput(paste(draft));
		terminal.sendInput("\r");
		const text = await confirmation(app);
		expect(text).toContain("Run this shell command?");
		expect(text).toContain("$ touch mention-marker");
		await cancelAndExpectDraft(app, terminal, draft);
		expect(existsSync(marker("mention-marker"))).toBe(false);
		expect(prompts(server)).toEqual([]);
	});

	test("a native selection edit inserting {!cmd} asks, and cancel runs nothing", async () => {
		const { app, server, terminal } = await bootApp();
		const draft = "{!touch native-edit-marker}";
		app.editor.handleNativeEvent({
			type: "edit",
			key: "",
			from: 0,
			to: 0,
			text: draft,
			cursor: draft.length,
			len: 0,
		});
		expect(app.editor.getExpandedText()).toBe(draft);
		terminal.sendInput("\r");
		expect(await confirmation(app)).toContain("$ touch native-edit-marker");
		await cancelAndExpectDraft(app, terminal, draft);
		expect(existsSync(marker("native-edit-marker"))).toBe(false);
		expect(prompts(server)).toEqual([]);
	});

	test("two separately inert pastes that join into {!cmd} ask, and cancel runs nothing", async () => {
		const { app, server, terminal } = await bootApp();
		terminal.sendInput(paste("{"));
		terminal.sendInput(paste("!touch joined-marker}"));
		terminal.sendInput("\r");
		expect(await confirmation(app)).toContain("$ touch joined-marker");
		await cancelAndExpectDraft(app, terminal, "{!touch joined-marker}");
		expect(existsSync(marker("joined-marker"))).toBe(false);
		expect(prompts(server)).toEqual([]);
	});

	test("a recalled prompt asks again before re-running its span", async () => {
		const { app, server, terminal } = await bootApp();
		type(terminal, "x {!touch history-marker}");
		terminal.sendInput("\r");
		await confirmation(app);
		terminal.sendInput(DOWN);
		terminal.sendInput("\r");
		expect(await sent(server)).toEqual(["x"]);
		expect(existsSync(marker("history-marker"))).toBe(true);
		rmSync(marker("history-marker"));
		terminal.sendInput(UP);
		expect(app.editor.getExpandedText()).toBe("x {!touch history-marker}");
		terminal.sendInput("\r");
		expect(await confirmation(app)).toContain("$ touch history-marker");
		await cancelAndExpectDraft(app, terminal, "x {!touch history-marker}");
		expect(existsSync(marker("history-marker"))).toBe(false);
		expect(prompts(server)).toEqual(["x"]);
	});

	test("Enter on the default Cancel row, typed text and pastes never run", async () => {
		const { app, server, terminal } = await bootApp();
		type(terminal, "!touch default-marker");
		terminal.sendInput("\r");
		await confirmation(app);
		type(terminal, "run");
		terminal.sendInput(paste("Run"));
		terminal.sendInput("\r");
		await waitFor(() => app.editor.getExpandedText() === "!touch default-marker", {
			what: "draft restored",
		});
		expect(existsSync(marker("default-marker"))).toBe(false);
		expect(prompts(server)).toEqual([]);
	});

	test("Run executes exactly the displayed command", async () => {
		const { app, terminal } = await bootApp();
		type(terminal, "!printf '%s' 'exact text' > exact-marker");
		terminal.sendInput("\r");
		const text = await confirmation(app);
		expect(text).toContain("$ printf '%s' 'exact text' > exact-marker");
		terminal.sendInput(DOWN);
		terminal.sendInput("\r");
		await waitFor(() => existsSync(marker("exact-marker")), { what: "confirmed command ran" });
		expect(await Bun.file(marker("exact-marker")).text()).toBe("exact text");
	});

	test("in a 12-column terminal a command that cannot be shown whole cannot run", async () => {
		const { app, server, terminal } = await bootApp();
		terminal.columns = 12;
		const draft = `!touch narrow-marker; : ${"x".repeat(120)}`;
		type(terminal, draft);
		terminal.sendInput("\r");
		await waitFor(() => app.selectors.isOpen, { what: "shell confirmation" });
		const text = overlayText(app);
		// Eight content columns: the command wraps to six-cell rows, overflows the
		// 24-row screen, and the body ends in the disabled-Run warning.
		expect(text).toContain("⚠");
		expect(text).not.toContain("x".repeat(120));
		terminal.sendInput(DOWN);
		terminal.sendInput("\r");
		// A decision closes the modal synchronously; still open means Run was refused.
		expect(app.selectors.isOpen).toBe(true);
		expect(existsSync(marker("narrow-marker"))).toBe(false);
		await cancelAndExpectDraft(app, terminal, draft);
		expect(existsSync(marker("narrow-marker"))).toBe(false);
		expect(prompts(server)).toEqual([]);
	});

	test("in a 12-column terminal a short command is wrapped whole and runs", async () => {
		const { app, terminal } = await bootApp();
		terminal.columns = 12;
		type(terminal, "!touch wrapped-marker");
		terminal.sendInput("\r");
		await waitFor(() => app.selectors.isOpen, { what: "shell confirmation" });
		const rows = overlayText(app);
		for (const piece of ["$ touch ", "↪ wrappe", "↪ d-mark", "↪ er"]) expect(rows).toContain(piece);
		terminal.sendInput(DOWN);
		terminal.sendInput("\r");
		await waitFor(() => existsSync(marker("wrapped-marker")), { what: "confirmed command ran" });
	});

	test("invisible characters in a command are spelled out, not hidden", async () => {
		const { app, terminal } = await bootApp();
		app.editor.handleNativeEvent({
			type: "edit",
			key: "",
			from: 0,
			to: 0,
			text: "{!echo safe\u202Eevil}",
			cursor: "{!echo safe\u202Eevil}".length,
			len: 0,
		});
		terminal.sendInput("\r");
		expect(await confirmation(app)).toContain("$ echo safe⟨U+202E⟩evil");
		terminal.sendInput(ESC);
	});
});

describe("confirmed captured escapes", () => {
	async function submitAndRun(app: AppShell, terminal: MemoryTerminal, text: string) {
		type(terminal, text);
		terminal.sendInput("\r");
		await confirmation(app);
		terminal.sendInput(DOWN);
		terminal.sendInput("\r");
	}

	test("a typed {!cmd} interpolates after Run", async () => {
		const { app, server, terminal } = await bootApp();
		await submitAndRun(app, terminal, "branch {!printf typed-output}");
		expect(await sent(server)).toEqual(["branch typed-output"]);
	});

	test("output is capped and the command is stopped", async () => {
		const { app, server, terminal } = await bootApp();
		await submitAndRun(app, terminal, "{!yes}");
		const [prompt] = await sent(server);
		const lines = prompt!.split("\n");
		expect(lines.length).toBeLessThanOrEqual(201);
		expect(prompt!.length).toBeLessThanOrEqual(64 * 1024 + 200);
		expect(lines.at(-1)).toContain("truncated");
		expect(renderPlain(app.chatContainer.render(100))).toContain("output exceeded");
	});

	test("Escape cancels an in-flight {!cmd} and keeps the draft", async () => {
		const { app, server, terminal } = await bootApp();
		const draft = "wait {!touch started-marker; sleep 30}";
		await submitAndRun(app, terminal, draft);
		await waitFor(() => existsSync(marker("started-marker")), { what: "command started" });
		const started = Date.now();
		terminal.sendInput(ESC);
		await waitFor(() => app.editor.getExpandedText() === draft, {
			timeoutMs: 3000,
			what: "draft restored after cancel",
		});
		expect(Date.now() - started).toBeLessThan(3000);
		expect(prompts(server)).toEqual([]);
		expect(renderPlain(app.chatContainer.render(100))).toContain("cancelled");
	});
});
