import { expect, test } from "bun:test";
import { TERMINAL } from "@oh-my-pi/pi-tui/terminal-capabilities";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import { resolveNotifications } from "../src/config.ts";
import { FakeControlPlane } from "../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../src/protocol/client.ts";
import { AppStore } from "../src/store/app-store.ts";
import { detectTerminalCapabilities } from "../src/terminal/capabilities.ts";
import { TerminalIntegration } from "../src/terminal/integration.ts";
import { codeLink, fileTarget, hyperlink } from "../src/terminal/links.ts";
import { TranscriptMarks } from "../src/terminal/marks.ts";
import { MemoryTerminal } from "./helpers/memory-terminal.ts";

test("Tern detection respects non-TTY, dumb, hyperlink and notification opt-outs", () => {
	const env = { TERN_PANE: "42", TERM: "xterm-256color" };
	expect(detectTerminalCapabilities(env, true)).toEqual({
		enabled: true,
		tern: true,
		hyperlinks: true,
		notifications: "osc9",
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
	const proc = Bun.spawn(
		[process.execPath, "src/main.ts", "--ws-url", server.url, "--session", "terminal-smoke"],
		{
			cwd: new URL("..", import.meta.url).pathname,
			env: {
				...process.env,
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
		await until(
			() =>
				output.includes("\x1b]133;D;0\x07") && output.includes("\x1b]7501;state=done:app=lemon"),
		);
		expect(output).toContain("\x1b]133;A\x07");
		expect(output).toContain("\x1b]133;B\x07");
		expect(output).toContain("\x1b]133;C\x07");
		expect(output).toContain("\x1b]7501;state=working:app=lemon\x1b\\");
		expect(output).toContain("\x1b]7;file://");
		expect(output).toContain("/src/main.ts#L12\x07");
		expect(output).toContain("\x1b]8;;https://example.com\x07");
		expect(output).toContain("\x1b]0;Lemon · terminal-smoke · ready\x07");
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
	} finally {
		if (proc.exitCode === null) {
			proc.kill();
			await proc.exited;
		}
		terminal.close();
		server.stop();
	}
}, 15000);
