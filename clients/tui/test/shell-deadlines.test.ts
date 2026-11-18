/**
 * The 120 s deadline on a fake clock: it bounds captured `{!cmd}` only. An
 * interactive `!cmd` owns the terminal (`!vim`, `!git rebase -i`, `!ssh`) and
 * must never be signalled by the TUI.
 */

import { afterEach, describe, expect, jest, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DEFAULT_SHELL_TIMEOUT_MS, runShellCommand } from "../src/shell.ts";

let dir: string | undefined;

afterEach(() => {
	jest.useRealTimers();
	// Removing the directory also removes `ready`, which ends a leftover probe.
	if (dir) rmSync(dir, { recursive: true, force: true });
	dir = undefined;
});

/**
 * Real time passes for the child while every JS timer stays frozen. The fake
 * clock also freezes `Date.now()`, so the budget is counted in 10 ms waits.
 */
function waitForFile(path: string, timeoutMs: number): boolean {
	for (let waited = 0; waited < timeoutMs; waited += 10) {
		if (existsSync(path)) return true;
		Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
	}
	return existsSync(path);
}

/** A SIGTERM the child receives is recorded in `term`; `stop` ends it. */
function probe(): string {
	dir = mkdtempSync(join(tmpdir(), "lemon-tui-shell-clock-"));
	return `trap 'echo term > "${dir}/term"; exit 143' TERM; echo ready > "${dir}/ready"; while [ -f "${dir}/ready" ] && [ ! -f "${dir}/stop" ]; do sleep 0.02; done`;
}

describe.skipIf(process.platform === "win32")("deadlines on a fake clock", () => {
	test("interactive !sleep-like command is not signalled at 120 s", async () => {
		jest.useFakeTimers();
		const pending = runShellCommand(probe(), { interactive: true });
		expect(waitForFile(join(dir!, "ready"), 5_000)).toBe(true);
		jest.advanceTimersByTime(DEFAULT_SHELL_TIMEOUT_MS + 1_000);
		jest.advanceTimersByTime(1_000);
		expect(waitForFile(join(dir!, "term"), 500)).toBe(false);
		writeFileSync(join(dir!, "stop"), "");
		const result = await pending;
		expect(result.failure).toBeUndefined();
		expect(result.code).toBe(0);
	});

	test("captured {!cmd} still times out at the default deadline", async () => {
		jest.useFakeTimers();
		const pending = runShellCommand(probe());
		expect(waitForFile(join(dir!, "ready"), 5_000)).toBe(true);
		jest.advanceTimersByTime(DEFAULT_SHELL_TIMEOUT_MS - 1_000);
		expect(waitForFile(join(dir!, "term"), 200)).toBe(false);
		jest.advanceTimersByTime(1_000);
		expect(waitForFile(join(dir!, "term"), 2_000)).toBe(true);
		jest.advanceTimersByTime(250);
		const result = await pending;
		expect(result.failure).toBe(`timed out after ${DEFAULT_SHELL_TIMEOUT_MS}ms`);
	});
});
