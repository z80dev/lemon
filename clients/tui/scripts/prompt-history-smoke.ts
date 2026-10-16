/**
 * Exercise an already-compiled TUI (no builds or provider calls):
 *   bun run scripts/prompt-history-smoke.ts /absolute/path/to/lemon-tui
 * Uses an isolated HOME, a loopback fake control plane and real child PTYs.
 */
import { Database } from "bun:sqlite";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { FakeControlPlane } from "../src/dev/fake-server.ts";

const binaryArg = process.argv[2];
assert(binaryArg, "usage: bun run scripts/prompt-history-smoke.ts /path/to/compiled/lemon-tui");
const binary = resolve(binaryArg);
assert(statSync(binary).isFile(), "compiled TUI must be a regular executable file");
const home = mkdtempSync(join(tmpdir(), "lemon-compiled-history-"));
const history = join(home, ".lemon", "tui-history", "history.sqlite3");
const prompt = "compiled SQLite prompt recall smoke";
const sessionKey = "compiled-history-smoke";
const server = await FakeControlPlane.start({
	methods: ["chat.send", "chat.history", "models.list", "status", "health"],
});
server.respondWith("chat.send", { runId: "history-smoke-run", sessionKey });
server.respondWith("chat.history", { messages: [] });
server.respondWith("models.list", {
	models: [{ id: "fixture-model", provider: "fixture", contextWindow: 200_000 }],
});
server.respondWith("status", { server: { version: "history-fixture" }, runs: { active: 0 } });
server.respondWith("health", { status: "ok" });

function savedPrompts(): string[] {
	const db = new Database(history, { readonly: true });
	try {
		return db
			.query<{ prompt: string }, []>("SELECT prompt FROM prompts ORDER BY id")
			.all()
			.map((row) => row.prompt);
	} finally {
		db.close();
	}
}

function launch() {
	let output = "";
	let keyboardAnswered = false;
	const decoder = new TextDecoder();
	const terminal = new Bun.Terminal({
		cols: 110,
		rows: 30,
		data(pty, bytes) {
			output += decoder.decode(bytes, { stream: true });
			if (!keyboardAnswered && output.includes("\x1b[?u")) {
				keyboardAnswered = true;
				pty.write("\x1b[?0u\x1b[?1;2c");
			}
		},
	});
	const proc = Bun.spawn([binary, "--ws-url", server.url, "--session", sessionKey], {
		cwd: home,
		env: {
			...process.env,
			HOME: home,
			TERM: "xterm-256color",
			TERM_PROGRAM: "",
			TERN_PANE: "",
			TMUX: "",
			STY: "",
			LEMON_CONTROL_PLANE_OPERATOR_TOKEN: "",
			LEMON_WS_TOKEN: "",
			PI_TUI_NATIVE: "0",
			LEMON_TUI_NOTIFICATIONS: "0",
		},
		terminal,
	});
	return {
		terminal,
		async until(predicate: (text: string) => boolean, description: string) {
			const deadline = Date.now() + 10_000;
			while (!predicate(output)) {
				assert.equal(proc.exitCode, null, `TUI exited before ${description}`);
				assert(Date.now() < deadline, `timed out waiting for ${description}`);
				await Bun.sleep(10);
			}
		},
		async quit() {
			terminal.write("\x04");
			const deadline = Date.now() + 10_000;
			while (proc.exitCode === null) {
				assert(Date.now() < deadline, "TUI did not exit on Ctrl+D");
				await Bun.sleep(10);
			}
			assert.equal(await proc.exited, 0, "compiled TUI exit status");
		},
		async close() {
			if (proc.exitCode === null) {
				proc.kill();
				await proc.exited;
			}
			terminal.close();
		},
	};
}

try {
	const first = launch();
	try {
		await first.until(
			(text) => text.includes("online") && text.includes("\x1b[>5u"),
			"first startup",
		);
		first.terminal.write(`${prompt}\r`);
		const request = await server.waitForRequest("chat.send", 10_000);
		const params = request.params;
		assert(params && typeof params === "object" && "prompt" in params, "chat.send prompt field");
		assert.equal(params.prompt, prompt);
		await first.quit();
	} finally {
		await first.close();
	}
	assert.equal(readFileSync(history).subarray(0, 16).toString(), "SQLite format 3\0");
	assert.deepEqual(savedPrompts(), [prompt]);
	assert.equal(statSync(history).mode & 0o777, 0o600);
	assert.equal(statSync(join(home, ".lemon", "tui-history")).mode & 0o777, 0o700);
	const inode = statSync(history).ino;

	const second = launch();
	try {
		await second.until(
			(text) => text.includes("online") && text.includes("\x1b[>5u"),
			"second startup",
		);
		second.terminal.write("\x1b[A");
		await second.until((text) => text.includes(prompt), "cross-process ↑ recall");
		assert.equal(server.requestsFor("chat.send").length, 1, "recall must not submit a prompt");
		assert.deepEqual(savedPrompts(), [prompt], "recall must not append a prompt");
		second.terminal.write("\x03");
		// Bracketed paste bypasses the slash palette and submits through the editor.
		second.terminal.write("\x1b[200~/clear-history\x1b[201~\r");
		await second.until((text) => text.includes("prompt history cleared"), "clear-history receipt");
		assert.deepEqual(
			savedPrompts(),
			[],
			"clear-history must not persist itself or the discarded draft",
		);
		assert.equal(statSync(history).ino, inode, "clear-history must retain the database inode");
		second.terminal.write("\x1b[A");
		await second.quit();
	} finally {
		await second.close();
	}
	assert.deepEqual(savedPrompts(), []);
	assert.equal(server.requestsFor("chat.send").length, 1, "clear-history stays client-local");
	console.log("PASS: compiled TUI SQLite submission, cross-process recall and clear-history");
} finally {
	server.stop();
	rmSync(home, { recursive: true, force: true });
}
