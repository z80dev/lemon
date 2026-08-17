/**
 * Shell escapes in the prompt.
 *
 *   `!cmd`      — a line that starts with `!` runs `cmd` instead of being sent.
 *   `{!cmd}`    — spans anywhere in a prompt are replaced by the command's
 *                 stdout before the prompt goes to the daemon.
 *
 * The two differ in more than syntax: the first is interactive (the caller
 * suspends the TUI so the command owns the terminal), the second is captured
 * and must never take the terminal, because the user is mid-prompt.
 *
 * Nothing here touches pi-tui; suspension is the controller's job, which keeps
 * this file testable without a terminal.
 */

export interface ShellResult {
	command: string;
	code: number;
	stdout: string;
	stderr: string;
	/** Set when the command could not be started or exceeded its deadline. */
	failure?: string;
}

export interface RunShellOptions {
	cwd?: string;
	timeoutMs?: number;
	/** The command inherits the terminal instead of being captured. */
	interactive?: boolean;
	env?: Record<string, string | undefined>;
}

export const DEFAULT_SHELL_TIMEOUT_MS = 120_000;

/** The shell used for `!` and `{!}`; `$SHELL` when set, else /bin/sh. */
export function shellBinary(env: NodeJS.ProcessEnv = process.env): string {
	return env.LEMON_TUI_SHELL || env.SHELL || "/bin/sh";
}

/** True when the line is a `!cmd` escape rather than a prompt. */
export function isShellLine(text: string): boolean {
	const trimmed = text.trimStart();
	// `!!` is shell history syntax the user probably meant literally, and a bare
	// `!` is not a command.
	return trimmed.startsWith("!") && !trimmed.startsWith("!!") && trimmed.trim().length > 1;
}

/** The command inside a `!cmd` line. */
export function shellLineCommand(text: string): string {
	return text.trimStart().slice(1).trim();
}

export interface ShellSpan {
	/** Index of the `{` in the source text. */
	start: number;
	/** Index just past the `}`. */
	end: number;
	command: string;
}

/**
 * Locate `{!cmd}` spans. `\{!` escapes the opener, so a prompt can talk about
 * the syntax without triggering it. Spans do not nest and stop at the first
 * unescaped `}`.
 */
export function findShellSpans(text: string): ShellSpan[] {
	const spans: ShellSpan[] = [];
	for (let index = 0; index < text.length - 1; index++) {
		if (text[index] !== "{" || text[index + 1] !== "!") continue;
		if (index > 0 && text[index - 1] === "\\") continue;
		const close = text.indexOf("}", index + 2);
		if (close === -1) break;
		const command = text.slice(index + 2, close).trim();
		if (command.length === 0) continue;
		spans.push({ start: index, end: close + 1, command });
		index = close;
	}
	return spans;
}

export function hasShellSpans(text: string): boolean {
	return findShellSpans(text).length > 0;
}

/** Drop the escaping backslash from `\{!` once interpolation is done. */
export function unescapeShellSpans(text: string): string {
	return text.replace(/\\\{!/g, "{!");
}

/**
 * Replace every `{!cmd}` span with the command's stdout (trailing newline
 * trimmed). A failing command is replaced by its stderr so the model sees what
 * went wrong instead of a silent gap; `onResult` lets the caller report it too.
 */
export async function interpolateShellSpans(
	text: string,
	run: (command: string) => Promise<ShellResult>,
	onResult?: (result: ShellResult) => void,
): Promise<string> {
	const spans = findShellSpans(text);
	if (spans.length === 0) return unescapeShellSpans(text);
	let output = "";
	let cursor = 0;
	for (const span of spans) {
		output += text.slice(cursor, span.start);
		const result = await run(span.command);
		onResult?.(result);
		const body = result.code === 0 ? result.stdout : result.stderr || result.failure || "";
		output += body.replace(/\n+$/, "");
		cursor = span.end;
	}
	output += text.slice(cursor);
	return unescapeShellSpans(output);
}

/**
 * Run a command through the shell. Never throws: a spawn failure or a timeout
 * comes back as a result with a non-zero code and a `failure` message, because
 * every caller wants to show it rather than handle it.
 */
export async function runShellCommand(
	command: string,
	options: RunShellOptions = {},
): Promise<ShellResult> {
	const timeoutMs = options.timeoutMs ?? DEFAULT_SHELL_TIMEOUT_MS;
	const base: ShellResult = { command, code: 0, stdout: "", stderr: "" };
	try {
		const proc = Bun.spawn([shellBinary(), "-c", command], {
			cwd: options.cwd ?? process.cwd(),
			env: { ...process.env, ...options.env } as Record<string, string>,
			stdin: options.interactive ? "inherit" : "ignore",
			stdout: options.interactive ? "inherit" : "pipe",
			stderr: options.interactive ? "inherit" : "pipe",
		});

		let timedOut = false;
		const timer =
			timeoutMs > 0
				? setTimeout(() => {
						timedOut = true;
						proc.kill();
					}, timeoutMs)
				: undefined;
		timer?.unref?.();

		const [stdout, stderr] = options.interactive
			? ["", ""]
			: await Promise.all([readStream(proc.stdout), readStream(proc.stderr)]);
		const code = await proc.exited;
		if (timer) clearTimeout(timer);

		return {
			...base,
			code,
			stdout,
			stderr,
			failure: timedOut ? `timed out after ${timeoutMs}ms` : undefined,
		};
	} catch (error) {
		return {
			...base,
			code: 127,
			failure: error instanceof Error ? error.message : String(error),
		};
	}
}

async function readStream(
	stream: ReadableStream<Uint8Array> | number | undefined,
): Promise<string> {
	if (!stream || typeof stream === "number") return "";
	return await new Response(stream).text();
}

/** The transcript body for a finished `!cmd`, trimmed to `maxLines`. */
export function formatShellResult(result: ShellResult, maxLines = 40): string[] {
	const lines = [`$ ${result.command}`];
	const body = [result.stdout, result.stderr].filter(Boolean).join("\n").split("\n");
	const trimmed = body.filter((line, index) => line.length > 0 || index < body.length - 1);
	if (trimmed.length > maxLines) {
		lines.push(...trimmed.slice(0, maxLines), `… ${trimmed.length - maxLines} more line(s)`);
	} else {
		lines.push(...trimmed);
	}
	if (result.failure) lines.push(`(${result.failure})`);
	else if (result.code !== 0) lines.push(`(exit ${result.code})`);
	return lines;
}
