import type { Terminal, TerminalAppearance } from "@oh-my-pi/pi-tui/terminal";

/**
 * Headless {@link Terminal} for tests: records writes, never touches stdio.
 * pi-tui also ships a VirtualTerminal, but that one pulls in ghostty-web, which
 * is a devDependency of pi-tui and not installed here.
 */
export class MemoryTerminal implements Terminal {
	readonly writes: string[] = [];
	columns = 80;
	rows = 24;
	appearance: TerminalAppearance | undefined = "dark";
	kittyProtocolActive = false;
	kittyEnableSequence: string | null = null;

	#onInput: ((data: string) => void) | undefined;

	start(onInput: (data: string) => void): void {
		this.#onInput = onInput;
	}

	stop(): void {
		this.#onInput = undefined;
	}

	/** Feed a key sequence as if it were typed. */
	sendInput(data: string): void {
		this.#onInput?.(data);
	}

	async drainInput(): Promise<void> {}

	write(data: string): void {
		this.writes.push(data);
	}

	moveBy(): void {}
	hideCursor(): void {}
	showCursor(): void {}
	clearLine(): void {}
	clearFromCursor(): void {}
	clearScreen(): void {}
	setTitle(): void {}
	setProgress(): void {}
	onAppearanceChange(callback: (appearance: TerminalAppearance) => void): void {
		callback("dark");
	}
}

// Built from variables rather than a literal so the pattern can carry the ESC
// and BEL control characters a regex literal is not allowed to spell out.
const ESC = String.fromCharCode(27);
const BEL = String.fromCharCode(7);
const ANSI_PATTERN = new RegExp(
	`${ESC}\\[[0-9;?]*[A-Za-z]|${ESC}\\][^${BEL}${ESC}]*(?:${BEL}|${ESC}\\\\)`,
	"g",
);
const TEXT_SIZING_PATTERN = new RegExp(`${ESC}\\]66;[^;]*;([^${ESC}]*)${ESC}\\\\`, "g");

export function stripAnsi(text: string): string {
	// OSC 66 carries visible text inside the control sequence. Preserve its
	// payload before removing ordinary ANSI/OSC wrappers.
	return text.replace(TEXT_SIZING_PATTERN, "$1").replace(ANSI_PATTERN, "");
}

export function renderPlain(lines: readonly string[]): string {
	return lines.map((line) => stripAnsi(line).trimEnd()).join("\n");
}

/** C0/DEL bytes other than tab and newline: in colorless output they can only come from data. */
// biome-ignore lint/suspicious/noControlCharactersInRegex: Detecting leaked terminal controls is the point.
export const TERMINAL_CONTROLS = /[\u0000-\u0008\u000b-\u001f\u007f]/;

const SGR = new RegExp(`${ESC}\\[[0-9;:]*m`, "g");
const HYPERLINK = new RegExp(
	`${ESC}\\]8;[^${BEL}${ESC}]*;([^${BEL}${ESC}]*)(?:${BEL}|${ESC}\\\\)`,
	"g",
);
/** Sequences only data can produce: retitles, clipboard, Lemon's status channels, cursor moves, clears. */
const DATA_SEQUENCES = new RegExp(
	`${ESC}\\](?:0|1|2|52|1337|7501);|${ESC}\\[[0-9;?]*[ABCDEFGHJKSTfsu]`,
);
const C1 = /[\u0080-\u009f]/;

/**
 * The first terminal control in rendered bytes that the theme could not have
 * written, or undefined. SGR colour is the theme's; a hyperlink is the
 * theme's only when its target is not `https://evil.example/` (the probe
 * tests inject); anything else — OSC 0/2/52/1337/7501, cursor movement, a
 * clear, BEL or another C0/C1 byte — came from untrusted data.
 */
export function injectedControl(raw: string): string | undefined {
	const sequence = DATA_SEQUENCES.exec(raw);
	if (sequence) return JSON.stringify(sequence[0]);
	for (const link of raw.matchAll(HYPERLINK)) {
		if (link[1]?.includes("evil.example")) return JSON.stringify(link[0]);
	}
	const rest = raw.replace(SGR, "").replace(HYPERLINK, "");
	const control = TERMINAL_CONTROLS.exec(rest) ?? C1.exec(rest);
	return control ? JSON.stringify(control[0]) : undefined;
}
