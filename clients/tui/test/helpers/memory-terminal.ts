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

export function stripAnsi(text: string): string {
	return text.replace(ANSI_PATTERN, "");
}

export function renderPlain(lines: readonly string[]): string {
	return lines.map((line) => stripAnsi(line).trimEnd()).join("\n");
}
