/**
 * The submit seam: what happens to a line between the editor and `chat.send`.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { ShellResult } from "../../src/shell.ts";
import { CommandController } from "../../src/ui/controllers/command-controller.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

let harness: Harness;
let delivered: string[];
let shellCalls: Array<{ command: string; interactive: boolean }>;
let suspends: string[];

function makeController(
	overrides: Partial<ConstructorParameters<typeof CommandController>[0]> = {},
) {
	return new CommandController({
		registry: harness.registry,
		store: harness.store,
		methods: harness.methods,
		client: harness.client,
		host: harness.host,
		sink: {
			deliver: async (text) => {
				delivered.push(text);
			},
		},
		tui: {
			stop: () => suspends.push("stop"),
			start: () => suspends.push("start"),
		},
		runShell: async (command, options): Promise<ShellResult> => {
			shellCalls.push({ command, interactive: options?.interactive === true });
			if (command.startsWith("fail")) {
				return { command, code: 1, stdout: "", stderr: "it failed" };
			}
			return { command, code: 0, stdout: `out(${command})\n`, stderr: "" };
		},
		...overrides,
	});
}

beforeEach(async () => {
	initTheme({ colorLevel: 3 });
	harness = await createHarness();
	delivered = [];
	shellCalls = [];
	suspends = [];
});

afterEach(() => {
	harness.stop();
	resetTheme();
	invalidateThemeAdapters();
});

describe("routing", () => {
	test("a prompt goes straight to the sink", async () => {
		await makeController().handleSubmit("what is the status?");
		expect(delivered).toEqual(["what is the status?"]);
		expect(shellCalls).toHaveLength(0);
	});

	test("a slash command never reaches the sink", async () => {
		await makeController().handleSubmit("/mode steer");
		expect(delivered).toHaveLength(0);
		expect(harness.store.submissionMode).toBe("steer");
	});

	test("an empty line does nothing", async () => {
		await makeController().handleSubmit("   ");
		expect(delivered).toHaveLength(0);
	});

	test("a path-looking line is a prompt, not a command", async () => {
		await makeController().handleSubmit("check /etc/hosts please");
		expect(delivered).toEqual(["check /etc/hosts please"]);
	});
});

describe("!cmd", () => {
	test("runs interactively with the terminal suspended and restored", async () => {
		await makeController().handleSubmit("!git status");
		expect(shellCalls).toEqual([{ command: "git status", interactive: true }]);
		expect(suspends).toEqual(["stop", "start"]);
		expect(delivered).toHaveLength(0);
		expect(harness.host.text).toContain("$ git status");
	});

	test("restores the terminal when the command throws", async () => {
		const controller = makeController({
			runShell: async () => {
				throw new Error("spawn failed");
			},
		});
		await controller.handleSubmit("!boom");
		expect(suspends).toEqual(["stop", "start"]);
		expect(harness.host.text).toContain("spawn failed");
	});

	test("a failing command is reported as a warning", async () => {
		await makeController().handleSubmit("!fail-now");
		expect(harness.host.last?.level).toBe("warning");
		expect(harness.host.text).toContain("exit 1");
	});
});

describe("{!cmd}", () => {
	test("interpolates output into the prompt before sending", async () => {
		await makeController().handleSubmit("branch: {!git branch}");
		expect(shellCalls).toEqual([{ command: "git branch", interactive: false }]);
		expect(delivered).toEqual(["branch: out(git branch)"]);
	});

	test("does not suspend the terminal", async () => {
		await makeController().handleSubmit("{!echo hi} and more");
		expect(suspends).toHaveLength(0);
	});

	test("a failing span is reported and still sends", async () => {
		await makeController().handleSubmit("x {!fail-me} y");
		expect(harness.host.text).toContain("it failed");
		expect(delivered).toEqual(["x it failed y"]);
	});

	test("an escaped span is sent literally", async () => {
		await makeController().handleSubmit("write \\{!cmd} in the docs");
		expect(shellCalls).toHaveLength(0);
		expect(delivered).toEqual(["write {!cmd} in the docs"]);
	});
});
