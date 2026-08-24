import { describe, expect, test } from "bun:test";
import {
	findShellSpans,
	formatShellResult,
	hasShellSpans,
	interpolateShellSpans,
	isShellLine,
	runShellCommand,
	type ShellResult,
	shellLineCommand,
} from "../src/shell.ts";

function fakeRun(outputs: Record<string, string>): (command: string) => Promise<ShellResult> {
	return async (command: string) => ({
		command,
		code: command in outputs ? 0 : 1,
		stdout: outputs[command] ?? "",
		stderr: command in outputs ? "" : `no such fake: ${command}`,
	});
}

describe("!cmd lines", () => {
	test("recognizes a leading bang", () => {
		expect(isShellLine("!ls -la")).toBe(true);
		expect(isShellLine("  !git status")).toBe(true);
	});

	test("leaves prose and history syntax alone", () => {
		expect(isShellLine("hey!")).toBe(false);
		expect(isShellLine("!")).toBe(false);
		expect(isShellLine("!!")).toBe(false);
		expect(isShellLine("wow! that is neat")).toBe(false);
	});

	test("strips the bang", () => {
		expect(shellLineCommand("  !git status  ")).toBe("git status");
	});
});

describe("{!cmd} spans", () => {
	test("finds one span", () => {
		expect(findShellSpans("context: {!git branch}")).toEqual([
			{ start: 9, end: 22, command: "git branch" },
		]);
	});

	test("finds several", () => {
		expect(findShellSpans("{!a} and {!b}").map((span) => span.command)).toEqual(["a", "b"]);
	});

	test("ignores an escaped opener", () => {
		expect(findShellSpans("write \\{!cmd} literally")).toEqual([]);
		expect(hasShellSpans("\\{!cmd}")).toBe(false);
	});

	test("ignores an unterminated span", () => {
		expect(findShellSpans("{!never closed")).toEqual([]);
	});

	test("ignores an empty span", () => {
		expect(findShellSpans("{!}")).toEqual([]);
	});

	test("does not treat a plain brace as a span", () => {
		expect(hasShellSpans("{ json: true }")).toBe(false);
	});
});

describe("interpolation", () => {
	test("replaces spans with stdout", async () => {
		const text = await interpolateShellSpans(
			"branch is {!git branch} today",
			fakeRun({ "git branch": "main\n" }),
		);
		expect(text).toBe("branch is main today");
	});

	test("replaces several spans in order", async () => {
		const text = await interpolateShellSpans("{!a}-{!b}", fakeRun({ a: "one", b: "two" }));
		expect(text).toBe("one-two");
	});

	test("a failing command contributes its stderr and is reported", async () => {
		const seen: ShellResult[] = [];
		const text = await interpolateShellSpans("x {!nope} y", fakeRun({}), (result) =>
			seen.push(result),
		);
		expect(text).toBe("x no such fake: nope y");
		expect(seen).toHaveLength(1);
		expect(seen[0].code).toBe(1);
	});

	test("text without spans is returned unchanged", async () => {
		expect(await interpolateShellSpans("plain prompt", fakeRun({}))).toBe("plain prompt");
	});

	test("the escape is removed once interpolation is done", async () => {
		expect(await interpolateShellSpans("\\{!literal}", fakeRun({}))).toBe("{!literal}");
	});
});

describe("runShellCommand", () => {
	test("captures stdout and the exit code", async () => {
		const result = await runShellCommand("echo hello");
		expect(result.code).toBe(0);
		expect(result.stdout.trim()).toBe("hello");
	});

	test("captures stderr and a non-zero exit", async () => {
		const result = await runShellCommand("echo oops 1>&2; exit 3");
		expect(result.code).toBe(3);
		expect(result.stderr.trim()).toBe("oops");
	});

	test("runs in the requested directory", async () => {
		const result = await runShellCommand("pwd", { cwd: "/tmp" });
		expect(result.stdout.trim()).toContain("tmp");
	});

	test("a command that overruns its deadline is killed and reported", async () => {
		const result = await runShellCommand("sleep 5", { timeoutMs: 50 });
		expect(result.failure).toContain("timed out");
		expect(result.code).not.toBe(0);
	});
});

describe("formatShellResult", () => {
	test("shows the command and its output", () => {
		const lines = formatShellResult({ command: "ls", code: 0, stdout: "a\nb\n", stderr: "" });
		expect(lines[0]).toBe("$ ls");
		expect(lines).toContain("a");
	});

	test("notes a non-zero exit", () => {
		const lines = formatShellResult({ command: "false", code: 1, stdout: "", stderr: "" });
		expect(lines[lines.length - 1]).toBe("(exit 1)");
	});

	test("truncates a long output", () => {
		const stdout = Array.from({ length: 100 }, (_, index) => `line ${index}`).join("\n");
		const lines = formatShellResult({ command: "seq", code: 0, stdout, stderr: "" }, 10);
		expect(lines.length).toBeLessThan(15);
		expect(lines[lines.length - 1]).toContain("more line(s)");
	});
});
