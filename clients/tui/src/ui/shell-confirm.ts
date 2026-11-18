/**
 * The confirmation every shell escape passes before anything runs.
 *
 * Composer text can reach the shell from places the TUI cannot tell apart from
 * typing (completions, native terminal edits, two pastes that join, history,
 * `$EDITOR`), so provenance is not the guard: the exact command text is. The
 * modal shows every command in full — wrapped to the width the picker actually
 * renders its rows at, with control, format and separator characters spelled
 * out — and runs only when the user moves to Run and presses Enter. If any
 * command row would be cut horizontally or vertically, Run is disabled. Enter
 * alone, Esc, typed or pasted text, and any other overlay replacing this one
 * all mean "do not run".
 */

import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import { isPrintable, PICKER_FRAME_COLUMNS, PickerOverlay } from "./components/pickers.ts";
import type { ShellConfirmRequest } from "./controllers/command-controller.ts";

/** Above this many characters across all commands the modal refuses to open. */
export const MAX_CONFIRM_CHARS = 4096;

/** Box borders, title, filter row, two choices and the footer. */
const CHROME_ROWS = 8;

const TOO_BIG =
	"⚠ cannot show in full at this size: Run is disabled (enlarge the terminal, or esc)";

// Characters a terminal would draw as nothing, as a cursor move, or as a
// different direction: shown as their code point so nothing in the command is
// hidden from the person confirming it.
const HIDDEN = /[\p{Cc}\p{Cf}\p{Cs}\p{Zl}\p{Zp}]/gu;

const segmenter = new Intl.Segmenter();

/** One source line with every invisible character spelled out. */
export function visibleCommandLine(line: string): string {
	return line.replace(
		HIDDEN,
		(char) => `⟨U+${char.codePointAt(0)!.toString(16).toUpperCase().padStart(4, "0")}⟩`,
	);
}

/**
 * The confirmation body for `width` content columns: a header, then each
 * command with `$ ` on its first line, `> ` on its other source lines and `↪ `
 * on soft-wrap continuations. Every character of every command appears exactly
 * once; a row is wider than `width` only when one grapheme cannot fit at all.
 */
export function shellConfirmLines(request: ShellConfirmRequest, width: number): string[] {
	const lines = [
		request.kind === "interactive"
			? "Runs in this terminal; the TUI waits until it exits:"
			: `Runs now; each output replaces its {!…} span in the prompt (${request.commands.length} command${request.commands.length === 1 ? "" : "s"}):`,
	];
	const room = width - 2;
	for (const command of request.commands) {
		command.split("\n").forEach((source, index) => {
			let prefix = index === 0 ? "$ " : "> ";
			let row = "";
			let used = 0;
			for (const { segment } of segmenter.segment(visibleCommandLine(source))) {
				const cells = visibleWidth(segment);
				if (used + cells > room && row !== "") {
					lines.push(prefix + row);
					prefix = "↪ ";
					row = "";
					used = 0;
				}
				row += segment;
				used += cells;
			}
			lines.push(prefix + row);
		});
	}
	return lines;
}

export interface ShellConfirmationOptions {
	request: ShellConfirmRequest;
	/** Terminal height: the overlay is fullscreen. */
	rows: () => number;
	/** Called once with the user's choice; the caller closes the overlay. */
	decide: (run: boolean) => void;
}

/** The modal; Cancel is the default row so a stray Enter runs nothing. */
export function createShellConfirmation(options: ShellConfirmationOptions): PickerOverlay {
	// Run is allowed only for the width the rows were last rendered at, and only
	// when that render showed every command row whole. Nothing rendered yet
	// means nothing was shown, so nothing may run.
	const shown = { width: 0, whole: false, runnable: false };
	const detail = () => {
		const content = shown.width - PICKER_FRAME_COLUMNS;
		const lines = shellConfirmLines(options.request, content);
		const capacity = Math.max(1, options.rows() - CHROME_ROWS);
		shown.whole =
			content > 2 &&
			lines.length <= capacity &&
			lines.slice(1).every((line) => visibleWidth(line) <= content);
		if (shown.whole) return lines;
		return [...lines.slice(0, Math.max(0, capacity - 1)), TOO_BIG];
	};
	class ShellConfirmation extends PickerOverlay {
		override render(width: number): readonly string[] {
			shown.width = width;
			const rendered = super.render(width);
			shown.runnable = shown.whole && rendered.length <= options.rows();
			return rendered;
		}
	}
	return new ShellConfirmation({
		title:
			options.request.kind === "interactive"
				? "Run this shell command?"
				: "Run these shell commands to build the prompt?",
		items: [
			{
				value: "cancel",
				label: "Cancel",
				description: "run nothing; the prompt returns to the composer",
			},
			{ value: "run", label: "Run", description: "run exactly the command text shown above" },
		],
		footer: "↓ to Run, then enter runs · enter on Cancel or esc runs nothing",
		maxVisible: 2,
		detail,
		// No filtering: typed or pasted text must never move the choice.
		onKey: (data) => isPrintable(data),
		onSelect: (item) => {
			if (item.value !== "run") options.decide(false);
			else if (shown.runnable) options.decide(true);
		},
		onCancel: () => options.decide(false),
	});
}
