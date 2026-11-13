import { describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setNativeRendering } from "@oh-my-pi/pi-tui/native/state";
import { TERMINAL } from "@oh-my-pi/pi-tui/terminal-capabilities";
import { routeTerminalMultiplexerNotification } from "@oh-my-pi/pi-tui/terminal-multiplexer";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import { PromptHistoryStore } from "../src/composer/prompt-history.ts";
import { resolveNotifications } from "../src/config.ts";
import { FakeControlPlane } from "../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../src/protocol/client.ts";
import { AppStore } from "../src/store/app-store.ts";
import { detectTerminalCapabilities } from "../src/terminal/capabilities.ts";
import { deliverNotification, TerminalIntegration } from "../src/terminal/integration.ts";
import { codeLink, fileTarget, hyperlink } from "../src/terminal/links.ts";
import { TranscriptMarks } from "../src/terminal/marks.ts";
import { encodeProgramStatusMessage } from "../src/terminal/signals.ts";
import { MemoryTerminal } from "./helpers/memory-terminal.ts";

test("Tern detection respects non-TTY, dumb, hyperlink and notification opt-outs", () => {
	const env = { TERN_PANE: "42", TERM: "xterm-256color" };
	expect(detectTerminalCapabilities(env, true)).toEqual({
		enabled: true,
		tern: true,
		hyperlinks: true,
		notifications: "osc9",
		routeNotifications: true,
	});
	expect(detectTerminalCapabilities({ TERM_PROGRAM: "Tern" }, true).tern).toBe(true);
	expect(detectTerminalCapabilities(env, false).enabled).toBe(false);
	expect(detectTerminalCapabilities({ ...env, TERM: "dumb" }, true).enabled).toBe(false);
	expect(detectTerminalCapabilities({ ...env, PI_NO_HYPERLINKS: "1" }, true).hyperlinks).toBe(
		false,
	);
	expect(
		detectTerminalCapabilities({ ...env, LEMON_TUI_NOTIFICATIONS: "0" }, true).notifications,
	).toBe(false);
});

test("notification config is overridden by env, and auto rings only for unknown terminals", () => {
	expect(resolveNotifications("bell", {})).toBe("bell");
	expect(resolveNotifications("bell", { LEMON_TUI_NOTIFICATIONS: "off" })).toBe("off");
	expect(resolveNotifications("bell", { LEMON_TUI_NOTIFICATIONS: "0" })).toBe("off");
	expect(resolveNotifications("off", { LEMON_TUI_NOTIFICATIONS: "1" })).toBe("auto");
	expect(resolveNotifications("off", { LEMON_TUI_NOTIFICATIONS: "osc" })).toBe("osc");
	expect(resolveNotifications("off", { LEMON_TUI_NOTIFICATIONS: "bell" })).toBe("bell");
	expect(detectTerminalCapabilities({ TERM_PROGRAM: "Apple_Terminal" }, true).notifications).toBe(
		"bell",
	);
	expect(detectTerminalCapabilities({}, true, "osc").notifications).toBe("osc777");
	expect(detectTerminalCapabilities({}, true, "off").notifications).toBe(false);
	expect(detectTerminalCapabilities({}, false, "bell").notifications).toBe(false);
});

test.each(["bell", "off"] as const)("approvals and run completion share %s mode", (mode) => {
	const terminal = new MemoryTerminal();
	const store = new AppStore("attention");
	store.setConnection("online");
	const client = new ControlPlaneClient({ url: "ws://127.0.0.1:1/ws" });
	const integration = new TerminalIntegration(
		terminal,
		store,
		client,
		"/repo",
		detectTerminalCapabilities({}, true, mode),
	);
	try {
		integration.start();
		terminal.writes.length = 0;
		store.addApproval({
			approvalId: "approval",
			runId: "run",
			sessionKey: "attention",
			agentId: null,
			rationale: null,
			requestedAtMs: Date.now(),
			tool: "bash",
			action: { command: "PRIVATE" },
			expiresAtMs: Date.now() + 60000,
		});
		client.events.emit("agent", { type: "started", runId: "run", sessionKey: "attention" });
		client.events.emit("agent", {
			type: "completed",
			runId: "run",
			sessionKey: "attention",
			ok: true,
			answer: "",
			durationMs: 1,
		});
		expect(terminal.writes.filter((write) => write === "\x07")).toHaveLength(
			mode === "bell" ? 2 : 0,
		);
		expect(terminal.writes.join("")).not.toContain("PRIVATE");
	} finally {
		integration.stop();
		client.close();
	}
});

describe("notification routing", () => {
	type Routing = Parameters<typeof deliverNotification>[4];
	function run(
		env: Record<string, string>,
		program: Record<string, string>,
		mode: "auto" | "osc" | "bell" | "off",
		options: { platform?: NodeJS.Platform; deliver?: boolean } = {},
	) {
		const writes: string[] = [];
		const desktop: unknown[] = [];
		const routed: unknown[] = [];
		const routing: NonNullable<Routing> = {
			env,
			platform: options.platform ?? "linux",
			route: (request) => {
				routed.push(request.sequence);
				return routeTerminalMultiplexerNotification(request);
			},
			desktop: (message) => desktop.push(message),
		};
		deliverNotification(
			detectTerminalCapabilities(program, true, mode),
			"Approval needed",
			"A tool is waiting",
			(data) => writes.push(data),
			routing,
		);
		return { writes, desktop, routed };
	}

	test("auto inside tmux wraps the terminal sequence in tmux passthrough", () => {
		const { writes, desktop } = run(
			{ TMUX: "/tmp/tmux-1/default,1,0" },
			{ TERM_PROGRAM: "iTerm.app" },
			"auto",
			{
				platform: "darwin",
			},
		);
		expect(writes).toEqual([
			"\x1bPtmux;\x1b\x1b]9;Lemon: Approval needed — A tool is waiting\x07\x1b\\\x07",
		]);
		expect(desktop).toEqual([]);
	});

	test("auto outside a multiplexer writes the terminal's own OSC and no desktop toast", () => {
		const { writes, desktop } = run(
			{ DBUS_SESSION_BUS_ADDRESS: "unix:path=/x" },
			{ TERM_PROGRAM: "foot" },
			"auto",
		);
		expect(writes).toEqual(["\x1b]777;notify;Lemon: Approval needed;A tool is waiting\x07"]);
		expect(desktop).toEqual([]);
	});

	test("auto on a bell-only Linux terminal rings and fires the desktop notifier", () => {
		const { writes, desktop } = run({ DBUS_SESSION_BUS_ADDRESS: "unix:path=/x" }, {}, "auto");
		expect(writes).toEqual(["\x07"]);
		expect(desktop).toEqual([{ title: "Lemon: Approval needed", body: "A tool is waiting" }]);
	});

	test("desktop notify needs a Linux session bus and honors PI_NO_DESKTOP_NOTIFY", () => {
		for (const [env, platform] of [
			[{}, "linux"],
			[{ DBUS_SESSION_BUS_ADDRESS: "unix:path=/x" }, "darwin"],
			[{ DBUS_SESSION_BUS_ADDRESS: "unix:path=/x", PI_NO_DESKTOP_NOTIFY: "1" }, "linux"],
		] as const) {
			const { writes, desktop } = run({ ...env }, {}, "auto", { platform });
			expect(writes).toEqual(["\x07"]);
			expect(desktop).toEqual([]);
		}
	});

	test("a bell-only terminal inside tmux rings instead of passing a sequence through", () => {
		const { writes, routed } = run({ TMUX: "1" }, {}, "auto", { platform: "darwin" });
		expect(routed).toEqual([null]);
		expect(writes).toEqual(["\x07"]);
	});

	test.each(["bell", "osc"] as const)(
		"%s mode never routes or fires the desktop notifier",
		(mode) => {
			const { writes, desktop, routed } = run(
				{ TMUX: "1", DBUS_SESSION_BUS_ADDRESS: "unix:path=/x" },
				{},
				mode,
			);
			expect(routed).toEqual([]);
			expect(desktop).toEqual([]);
			expect(writes).toEqual([
				mode === "bell" ? "\x07" : "\x1b]777;notify;Lemon: Approval needed;A tool is waiting\x07",
			]);
		},
	);

	test("off is silent", () => {
		const { writes, desktop, routed } = run(
			{ TMUX: "1", DBUS_SESSION_BUS_ADDRESS: "x" },
			{},
			"off",
		);
		expect([writes, desktop, routed]).toEqual([[], [], []]);
	});

	test("Tern keeps its program-status path: no OSC and no routing in auto", () => {
		const terminal = new MemoryTerminal();
		const store = new AppStore("tern-notify");
		store.setConnection("online");
		const client = new ControlPlaneClient({ url: "ws://127.0.0.1:1/ws" });
		const routed: unknown[] = [];
		const integration = new TerminalIntegration(
			terminal,
			store,
			client,
			"/repo",
			detectTerminalCapabilities({ TERM_PROGRAM: "Tern", TMUX: "1" }, true),
			undefined,
			{
				env: { TMUX: "1" },
				route: (request) => (routed.push(request), true),
				desktop: () => routed.push("d"),
			},
		);
		try {
			integration.start();
			terminal.writes.length = 0;
			store.addUserPrompt({ promptId: "q", sessionKey: "tern-notify", questions: [] });
			expect(routed).toEqual([]);
			expect(terminal.writes.join("")).not.toContain("]9;");
		} finally {
			integration.stop();
			client.close();
		}
	});
});

test("transcript marks preserve width, cached rows, and completion marks", () => {
	const marks = new TranscriptMarks(true);
	const rows = ["first", "last"];
	const running = marks.apply(rows, "running");
	expect(running[0]).toStartWith("\x1b]133;C\x07");
	expect(marks.apply(rows, "running")).toBe(running);
	expect(running.map(visibleWidth)).toEqual([5, 4]);
	expect(marks.apply(rows, "success")[1]).toEndWith("\x1b]133;D;0\x07");
	expect(marks.apply([], "error")[0]).toContain("\x1b]133;D;1\x07");
	expect(new TranscriptMarks(false).apply(rows, "prompt")).toBe(rows);
});

test("file links encode special characters, line anchors and reject control injection", () => {
	expect(fileTarget("src/a b#c.ts", 42, "/repo")).toBe("file:///repo/src/a%20b%23c.ts#L42");
	expect(fileTarget("src/a.ts\x1b]9;injected\x07")).toBeUndefined();
	const previous = TERMINAL.hyperlinks;
	try {
		TERMINAL.hyperlinks = true;
		expect(hyperlink("label", "https://example.com")).toContain(
			"\x1b]8;;https://example.com\x07label",
		);
		expect(codeLink("src/main.ts:12", "path")).toContain("/src/main.ts#L12\x07path");
		expect(hyperlink("safe", "https://example.com\x07bad")).toBe("safe");
	} finally {
		TERMINAL.hyperlinks = previous;
	}
});

test("publishes the finalized native frame before terminal completion becomes observable", async () => {
	const terminal = new MemoryTerminal();
	const store = new AppStore("native-order");
	store.setConnection("online");
	const client = new ControlPlaneClient({ url: "ws://127.0.0.1:1/ws" });
	let frame = "partial";
	const integration = new TerminalIntegration(
		terminal,
		store,
		client,
		"/repo",
		detectTerminalCapabilities({ TERM_PROGRAM: "Tern" }, true),
		() => terminal.write(frame),
	);
	try {
		integration.start();
		store.focused.busy = true;
		client.events.emit("agent", {
			type: "started",
			runId: "native-run",
			sessionKey: store.focusedKey,
		});
		await Promise.resolve();
		terminal.writes.length = 0;
		store.focused.busy = false;
		store.events.emit("blocks-changed", { key: store.focusedKey });
		frame = "complete final answer";
		client.events.emit("agent", {
			type: "completed",
			runId: "native-run",
			sessionKey: store.focusedKey,
			ok: true,
			answer: frame,
			durationMs: 1,
		});
		expect(terminal.writes.join("")).not.toContain("state=done");
		await Promise.resolve();
		const output = terminal.writes.join("");
		expect(output).toContain("complete final answer");
		expect(output.indexOf("complete final answer")).toBeLessThan(output.indexOf("state=done"));
	} finally {
		integration.stop();
		client.close();
	}
});

test("Tern reports pending action summaries, questions and failures, but not completed answers", () => {
	const terminal = new MemoryTerminal();
	const store = new AppStore("attention");
	store.setConnection("online");
	const client = new ControlPlaneClient({ url: "ws://127.0.0.1:1/ws" });
	const integration = new TerminalIntegration(
		terminal,
		store,
		client,
		"/repo",
		detectTerminalCapabilities({ TERM_PROGRAM: "Tern" }, true),
	);
	const report = (state: string, message?: string) =>
		`\x1b]7501;state=${state}:app=lemon${message ? `:msg=${encodeProgramStatusMessage(message)}` : ""}\x1b\\`;
	try {
		integration.start();
		store.addUserPrompt({
			promptId: "question",
			sessionKey: "attention",
			questions: [{ id: "branch", question: "Which\nbranch?", options: [] }],
		});
		expect(terminal.writes.at(-1)).toBe(report("blocked:kind=question", "Which branch?"));
		store.addApproval({
			approvalId: "approval",
			runId: "run",
			sessionKey: "attention",
			agentId: null,
			rationale: null,
			requestedAtMs: null,
			tool: "bash",
			action: { command: "git\nstatus" },
			expiresAtMs: null,
		});
		expect(terminal.writes.at(-1)).toBe(report("blocked:kind=permission", "git status"));
		store.addApproval({
			...store.approvals.get("approval")!.event,
			action: { title: "Review changes", command: "git diff" },
		});
		expect(terminal.writes.at(-1)).toBe(report("blocked:kind=permission", "Review changes"));
		store.resolveApproval("approval");
		expect(terminal.writes.at(-1)).toBe(report("blocked:kind=question", "Which branch?"));
		store.removeUserPrompt("question");
		for (const error of ["Provider\nfailed", { message: "Unavailable", code: "offline" }]) {
			client.events.emit("agent", { type: "started", runId: "run", sessionKey: "attention" });
			client.events.emit("agent", {
				type: "completed",
				runId: "run",
				sessionKey: "attention",
				ok: false,
				error,
				answer: "",
				durationMs: 1,
			});
			expect(terminal.writes.at(-1)).toBe(
				report("error", typeof error === "string" ? error : JSON.stringify(error)),
			);
		}
		client.events.emit("agent", { type: "started", runId: "done", sessionKey: "attention" });
		client.events.emit("agent", {
			type: "completed",
			runId: "done",
			sessionKey: "attention",
			ok: true,
			answer: "Do not publish completed answers",
			durationMs: 1,
		});
		expect(terminal.writes.at(-1)).toBe(report("done"));
	} finally {
		integration.stop();
		client.close();
	}
});

test("Tern reasserts the focused card after native surface open and resume", () => {
	const terminal = new (class extends MemoryTerminal {
		override setTitle(title = ""): void {
			this.writes.push(`title:${title}`);
		}
	})();
	const store = new AppStore("session-key");
	store.setConnection("online");
	const client = new ControlPlaneClient({ url: "ws://127.0.0.1:1/ws" });
	const integration = new TerminalIntegration(
		terminal,
		store,
		client,
		"/repo",
		detectTerminalCapabilities({ TERM_PROGRAM: "Tern" }, true),
	);
	try {
		integration.start();
		expect(terminal.writes).toContain("title:🍋 LEMON: session-key");
		terminal.writes.length = 0;
		terminal.write("surface-open");
		setNativeRendering(true);
		expect(terminal.writes).toEqual(["surface-open", "title:🍋 LEMON: session-key"]);
		store.focused.title = "🧪 FLAKY: Fix tests";
		integration.update();
		expect(terminal.writes.at(-1)).toBe("title:🧪 FLAKY: Fix tests");
		integration.suspend();
		setNativeRendering(false);
		terminal.writes.length = 0;
		terminal.write("surface-resume");
		setNativeRendering(true);
		integration.resume();
		expect(terminal.writes.indexOf("title:🧪 FLAKY: Fix tests")).toBeGreaterThan(
			terminal.writes.indexOf("surface-resume"),
		);
	} finally {
		integration.stop();
		setNativeRendering(false);
		client.close();
	}
});

test.each([
	["Tern", "\x1b]7501;state=idle:app=lemon\x1b\\"],
	["iTerm.app", "\x1b]9;Lemon: Turn interrupted — Return to Lemon to continue\x07"],
	["foot", "\x1b]777;notify;Lemon: Turn interrupted;Return to Lemon to continue\x07"],
])(
	"cancelled turns clear working status without failure notifications in %s",
	(program, signal) => {
		const terminal = new MemoryTerminal();
		const store = new AppStore("cancelled-turn");
		store.setConnection("online");
		const client = new ControlPlaneClient({ url: "ws://127.0.0.1:1/ws" });
		const integration = new TerminalIntegration(
			terminal,
			store,
			client,
			"/repo",
			detectTerminalCapabilities({ TERM_PROGRAM: program }, true),
		);
		try {
			integration.start();
			store.focused.busy = true;
			client.events.emit("agent", {
				type: "started",
				runId: "cancelled-run",
				sessionKey: store.focusedKey,
			});
			terminal.writes.length = 0;
			store.focused.busy = false;
			client.events.emit("agent", {
				type: "completed",
				runId: "cancelled-run",
				sessionKey: store.focusedKey,
				ok: false,
				cancelled: true,
				answer: "",
				durationMs: 1,
			});
			const output = terminal.writes.join("");
			expect(output).toContain(signal);
			expect(output).not.toContain("Turn failed");
			expect(output).not.toContain("Turn complete");
			expect(output).not.toContain("state=error");
			expect(output).not.toContain("state=done");
		} finally {
			integration.stop();
			client.close();
		}
	},
);

test("real TUI PTY emits turn/approval signals and restores keyboard, title and terminal modes", async () => {
	const server = await FakeControlPlane.start();
	server.respondWith("chat.send", { runId: "terminal-run", sessionKey: "terminal-smoke" });
	let output = "";
	let keyboardAnswered = false;
	let onOutput: (() => void) | undefined;
	const decoder = new TextDecoder();
	const terminal = new Bun.Terminal({
		cols: 100,
		rows: 30,
		data(pty, bytes) {
			output += decoder.decode(bytes, { stream: true });
			if (!keyboardAnswered && output.includes("\x1b[?u")) {
				keyboardAnswered = true;
				pty.write("\x1b[?0u\x1b[?1;2c");
			}
			onOutput?.();
		},
	});
	const originalFlags = terminal.localFlags;
	// The child saves prompt history under $HOME; keep that off the real ~/.lemon.
	const home = mkdtempSync(join(tmpdir(), "lemon-tui-pty-"));
	const proc = Bun.spawn(
		[process.execPath, "src/main.ts", "--ws-url", server.url, "--session", "terminal-smoke"],
		{
			cwd: new URL("..", import.meta.url).pathname,
			env: {
				...process.env,
				HOME: home,
				TERN_PANE: "terminal-smoke",
				TERM_PROGRAM: "Tern",
				TERM: "xterm-256color",
				TMUX: "",
				STY: "",
				LEMON_CONTROL_PLANE_OPERATOR_TOKEN: "",
				LEMON_WS_TOKEN: "",
				LEMON_TUI_TERMINAL_INTEGRATION: "1",
				LEMON_TUI_NOTIFICATIONS: "1",
				PI_NO_HYPERLINKS: "0",
				PI_TUI_NATIVE: "0",
			},
			terminal,
		},
	);
	const until = (predicate: () => boolean): Promise<void> => {
		if (predicate()) return Promise.resolve();
		const { promise, resolve } = Promise.withResolvers<void>();
		onOutput = () => {
			if (!predicate()) return;
			onOutput = undefined;
			resolve();
		};
		return promise;
	};
	try {
		await server.waitForConnection();
		await until(() => output.includes("online") && output.includes("\x1b[>5u"));
		terminal.write("terminal integration smoke\r");
		await server.waitForRequest("chat.send");
		server.pushEvent("agent", {
			type: "started",
			runId: "terminal-run",
			sessionKey: "terminal-smoke",
		});
		await until(() => output.includes("\x1b]9;4;3\x07"));
		server.pushEvent("exec.approval.requested", {
			approvalId: "terminal-approval",
			runId: "terminal-run",
			sessionKey: "terminal-smoke",
			tool: "bash",
			action: { command: "true" },
			expiresAtMs: Date.now() + 60000,
		});
		await until(() => output.includes("\x1b]7501;state=blocked:kind=permission:app=lemon"));
		server.pushEvent("exec.approval.resolved", {
			approvalId: "terminal-approval",
			decision: "once",
			runId: "terminal-run",
			sessionKey: "terminal-smoke",
		});
		server.pushEvent("chat", {
			type: "delta",
			runId: "terminal-run",
			sessionKey: "terminal-smoke",
			seq: 1,
			text: "Read `src/main.ts:12` and https://example.com",
		});
		server.pushEvent("agent", {
			type: "completed",
			runId: "terminal-run",
			sessionKey: "terminal-smoke",
			ok: true,
			answer: "",
			durationMs: 10,
		});
		// Completion status is emitted before the scheduled transcript render.
		// Wait for the answer's terminal frame as well as its lifecycle signals.
		await until(
			() =>
				output.includes("\x1b]133;D;0\x07") &&
				output.includes("\x1b]7501;state=done:app=lemon") &&
				output.includes("/src/main.ts#L12\x07") &&
				output.includes("\x1b]8;;https://example.com\x07"),
		);
		expect(output).toContain("\x1b]133;A\x07");
		expect(output).toContain("\x1b]133;B\x07");
		expect(output).toContain("\x1b]133;C\x07");
		expect(output).toContain("\x1b]7501;state=working:app=lemon\x1b\\");
		expect(output).toContain("\x1b]7;file://");
		expect(output).toContain("/src/main.ts#L12\x07");
		expect(output).toContain("\x1b]8;;https://example.com\x07");
		expect(output).toContain("\x1b]0;🍋 LEMON: terminal-smoke\x07");
		const cancelledOutputStart = output.length;
		server.pushEvent("agent", {
			type: "started",
			runId: "cancelled-run",
			sessionKey: "terminal-smoke",
		});
		await until(() => output.slice(cancelledOutputStart).includes("state=working"));
		server.pushEvent("agent", {
			type: "completed",
			runId: "cancelled-run",
			sessionKey: "terminal-smoke",
			ok: false,
			cancelled: true,
			answer: "",
		});
		await until(() => output.slice(cancelledOutputStart).includes("state=idle:app=lemon"));
		expect(output.slice(cancelledOutputStart)).not.toContain("state=error");
		expect(output.slice(cancelledOutputStart)).not.toContain("state=done");
		// Slash opens the palette; use direct exit to test terminal restoration.
		terminal.write("\x04");
		expect(await proc.exited).toBe(0);
		expect(output).toContain("\x1b[<u");
		expect(output).toContain("\x1b[?2004l");
		expect(output).toContain("\x1b[?25h");
		expect(output).toContain("\x1b]0;\x07");
		expect(output).toContain("\x1b[23;0t");
		expect(output).toContain("\x1b]1337;SetUserVar=lemon_session=\x07");
		expect(output).toContain("\x1b]7501;state=clear\x1b\\");
		expect(output).toContain("\x1b]9;4;0;");
		expect(terminal.localFlags).toBe(originalFlags);
		// Prompt history is on by default: saved privately under the scoped $HOME.
		const historyFile = join(home, ".lemon", "tui-history", "history.sqlite3");
		expect(new PromptHistoryStore(historyFile).load()).toEqual(["terminal integration smoke"]);
		expect(statSync(join(home, ".lemon", "tui-history")).mode & 0o777).toBe(0o700);
		expect(statSync(historyFile).mode & 0o777).toBe(0o600);
	} finally {
		if (proc.exitCode === null) {
			proc.kill();
			await proc.exited;
		}
		terminal.close();
		server.stop();
		rmSync(home, { recursive: true, force: true });
	}
}, 15000);
