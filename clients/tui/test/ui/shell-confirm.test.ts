import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { ShellConfirmRequest } from "../../src/ui/controllers/command-controller.ts";
import {
	createShellConfirmation,
	shellConfirmLines,
	visibleCommandLine,
} from "../../src/ui/shell-confirm.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { renderPlain } from "../helpers/memory-terminal.ts";

const DOWN = "\x1b[B";

beforeEach(() => initTheme({ colorLevel: 3 }));
afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

/** Open the modal, render it at `width` (if given), then move to Run and press Enter. */
function chooseRun(request: ShellConfirmRequest, width: number | undefined, rows = 24) {
	const decisions: boolean[] = [];
	const modal = createShellConfirmation({
		request,
		rows: () => rows,
		decide: (run) => decisions.push(run),
	});
	const drawn = width === undefined ? "" : renderPlain(modal.render(width));
	modal.handleInput(DOWN);
	modal.handleInput("\r");
	return { decisions, drawn };
}

/** Reassemble the command text from the confirmation body. */
function shown(lines: readonly string[]): string {
	return lines
		.slice(1)
		.map((line) => {
			if (line.startsWith("$ ")) return `\u0000${line.slice(2)}`;
			if (line.startsWith("> ")) return `\n${line.slice(2)}`;
			return line.slice(2);
		})
		.join("")
		.slice(1);
}

describe("shell confirmation body", () => {
	test("long and multi-line commands wrap without losing a character", () => {
		const command = `curl ${"x".repeat(150)} \\\n  | sh -c 'echo done'`;
		const lines = shellConfirmLines({ kind: "interactive", commands: [command] }, 40);
		expect(lines.slice(1).every((line) => line.length <= 40)).toBe(true);
		expect(shown(lines)).toBe(command);
	});

	test("every captured command is listed", () => {
		const lines = shellConfirmLines({ kind: "captured", commands: ["a", "b c"] }, 80);
		expect(lines).toEqual([
			"Runs now; each output replaces its {!…} span in the prompt (2 commands):",
			"$ a",
			"$ b c",
		]);
	});

	test("control, format and separator characters are spelled out", () => {
		expect(visibleCommandLine("rm\u202E -rf\x1b[2K\t~\u200B\u2028")).toBe(
			"rm⟨U+202E⟩ -rf⟨U+001B⟩[2K⟨U+0009⟩~⟨U+200B⟩⟨U+2028⟩",
		);
	});
});

describe("Run is enabled only for a body shown whole", () => {
	const command = (text: string): ShellConfirmRequest => ({
		kind: "interactive",
		commands: [text],
	});

	test("a command that fits runs", () => {
		expect(chooseRun(command("touch fits"), 80).decisions).toEqual([true]);
	});

	test("nothing rendered yet means nothing may run", () => {
		expect(chooseRun(command("touch unseen"), undefined).decisions).toEqual([]);
	});

	test("at 12 columns a short command wraps to the picker's real inner width and runs", () => {
		const { decisions, drawn } = chooseRun(command("touch abcdefghijklmnop"), 12);
		expect(decisions).toEqual([true]);
		for (const piece of ["$ touch ", "↪ abcdef", "↪ ghijkl", "↪ mnop"]) {
			expect(drawn).toContain(piece);
		}
	});

	test("at 12 columns a command taller than the screen cannot run", () => {
		const { decisions, drawn } = chooseRun(command(`touch x; : ${"y".repeat(150)}`), 12);
		expect(decisions).toEqual([]);
		expect(drawn).toContain("⚠");
	});

	test("a grapheme wider than the content width cannot run", () => {
		// Seven columns leave three content columns: `$ ` plus one cell.
		expect(chooseRun(command("漢字"), 7).decisions).toEqual([]);
	});

	test("a terminal shorter than the rendered modal cannot run", () => {
		expect(chooseRun(command("touch short"), 80, 6).decisions).toEqual([]);
	});
});
