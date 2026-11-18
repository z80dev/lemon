import { describe, expect, test } from "bun:test";
import {
	escapeShellSyntax,
	findShellSpans,
	formatShellResult,
	hasShellSpans,
	inertComposerText,
	interpolateShellSpans,
	isShellLine,
	MAX_CAPTURED_OUTPUT_BYTES,
	MAX_INTERPOLATED_LINES,
	runShellCommand,
	type ShellResult,
	shellLineCommand,
	unescapeShellSyntax,
} from "../src/shell.ts";

function fakeRun(outputs: Record<string, string>): (command: string) => Promise<ShellResult> {
	return async (command: string) => ({
		command,
		code: command in outputs ? 0 : 1,
		stdout: outputs[command] ?? "",
		stderr: command in outputs ? "" : `no such fake: ${command}`,
	});
}

function processIsAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ESRCH") return false;
		throw error;
	}
}

async function waitForProcessExit(pid: number, timeoutMs = 2_000): Promise<boolean> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		if (!processIsAlive(pid)) return true;
		await Bun.sleep(10);
	}
	return !processIsAlive(pid);
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

	test("command output is spliced verbatim, never unescaped", async () => {
		const text = await interpolateShellSpans("{!a}", fakeRun({ a: "\\{!b} and \\!c" }));
		expect(text).toBe("\\{!b} and \\!c");
	});

	test("a long output is capped to MAX_INTERPOLATED_LINES with a note", async () => {
		const many = Array.from({ length: 500 }, (_, index) => `row ${index}`).join("\n");
		const text = (await interpolateShellSpans("{!many}", fakeRun({ many })))!;
		const lines = text.split("\n");
		expect(lines).toHaveLength(MAX_INTERPOLATED_LINES + 1);
		expect(lines.at(-1)).toBe("[output of `many` truncated: 300 more line(s)]");
	});

	test("an aborted interpolation sends nothing and runs no further span", async () => {
		const controller = new AbortController();
		const ran: string[] = [];
		const text = await interpolateShellSpans(
			"{!first} {!second}",
			async (command) => {
				ran.push(command);
				controller.abort();
				return { command, code: 0, stdout: "x", stderr: "" };
			},
			undefined,
			controller.signal,
		);
		expect(text).toBeUndefined();
		expect(ran).toEqual(["first"]);
	});
});

describe("text that was not typed", () => {
	const samples = [
		"{!touch /tmp/pwned}",
		"return <div>{!loading && <Spinner/>}</div>;",
		"\\{!already escaped}",
		"!rm -rf ~",
		"  !indented",
		"\\!escaped bang",
		"!!",
		"a {!b} \\{!c} \\\\{!d}",
	];

	test.each(samples)("%j is inert once escaped and round-trips exactly", async (sample) => {
		const escaped = escapeShellSyntax(sample);
		expect(findShellSpans(escaped)).toEqual([]);
		expect(isShellLine(escaped)).toBe(false);
		expect(unescapeShellSyntax(escaped)).toBe(sample);
		const run = async (command: string): Promise<ShellResult> => {
			throw new Error(`ran ${command}`);
		};
		expect(await interpolateShellSpans(escaped, run)).toBe(sample);
	});

	test("a fragment that does not open the prompt keeps its bang", () => {
		expect(escapeShellSyntax("!x {!y}", false)).toBe("!x \\{!y}");
		expect(unescapeShellSyntax("!x \\{!y}", false)).toBe("!x {!y}");
	});

	test("control bytes are stripped before escaping, so they cannot join `{` and `!`", () => {
		expect(inertComposerText("a {\x01!touch x}")).toBe("a \\{!touch x}");
		expect(inertComposerText("\x01!touch x")).toBe("\\!touch x");
		expect(inertComposerText("{\r\n!x}")).toBe("{\n!x}");
		expect(findShellSpans(inertComposerText("{\x1f!a} {\x00!b}"))).toEqual([]);
	});
});

describe("captured output limits", () => {
	test.skipIf(process.platform === "win32")(
		"an endless producer is stopped at the byte cap",
		async () => {
			const started = Date.now();
			const result = await runShellCommand("yes");
			expect(Date.now() - started).toBeLessThan(5_000);
			expect(result.truncated).toBe(true);
			expect(Buffer.byteLength(result.stdout)).toBeLessThanOrEqual(MAX_CAPTURED_OUTPUT_BYTES);
			expect(result.failure).toContain("output exceeded");
		},
	);

	test.skipIf(process.platform === "win32")(
		"an aborted command is stopped and reported as cancelled",
		async () => {
			const controller = new AbortController();
			const started = Date.now();
			const pending = runShellCommand("sleep 30", { signal: controller.signal });
			controller.abort();
			const result = await pending;
			expect(Date.now() - started).toBeLessThan(5_000);
			expect(result.failure).toBe("cancelled");
		},
	);
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

	test.skipIf(process.platform === "win32")(
		"kills a TERM-resistant descendant after its parent closes the capture pipes",
		async () => {
			let descendantPid: number | undefined;

			try {
				const result = await runShellCommand(
					`/bin/sh -c 'trap "" TERM HUP; while :; do sleep 1; done' </dev/null >/dev/null 2>&1 & child=$!; echo "$child"; wait "$child"`,
					{ timeoutMs: 50 },
				);

				descendantPid = Number.parseInt(result.stdout.trim(), 10);
				expect(result.failure).toContain("timed out");
				expect(Number.isSafeInteger(descendantPid)).toBe(true);
				expect(await waitForProcessExit(descendantPid)).toBe(true);
			} finally {
				if (descendantPid && processIsAlive(descendantPid)) {
					process.kill(descendantPid, "SIGKILL");
				}
			}
		},
	);
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
