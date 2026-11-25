/**
 * Shell escapes in the prompt.
 *
 *   `!cmd`      — a line that starts with `!` runs `cmd` instead of being sent.
 *   `{!cmd}`    — spans anywhere in a prompt are replaced by the command's
 *                 stdout before the prompt goes to the daemon.
 *
 * The two differ in more than syntax: the first is interactive (the caller
 * suspends the TUI so the command owns the terminal and no deadline applies),
 * the second is captured, bounded in time and size, and must never take the
 * terminal, because the user is mid-prompt.
 *
 * Neither runs before the user confirms the exact command text at submit (the
 * command controller's `confirmShell`), wherever the text came from. As a
 * usability layer, text that enters the composer other than by typing — a
 * paste, a skill from the palette, a restored queue item or
 * rewound prompt, a delegated send — is escaped first
 * ({@link inertComposerText}), so it reaches the model verbatim without asking.
 *
 * Nothing here touches pi-tui; suspension is the controller's job, which keeps
 * this file testable without a terminal.
 */

export interface ShellResult {
	command: string;
	code: number;
	stdout: string;
	stderr: string;
	/** Set when the command could not be started, was stopped, or exceeded a limit. */
	failure?: string;
	/** Captured output hit {@link MAX_CAPTURED_OUTPUT_BYTES}; stdout holds the kept prefix. */
	truncated?: boolean;
}

export interface RunShellOptions {
	cwd?: string;
	/** Captured commands default to {@link DEFAULT_SHELL_TIMEOUT_MS}; interactive ones to none. */
	timeoutMs?: number;
	/** The command inherits the terminal instead of being captured. */
	interactive?: boolean;
	env?: Record<string, string | undefined>;
	/** Aborting stops the command's process tree; the result reports `cancelled`. */
	signal?: AbortSignal;
}

export const DEFAULT_SHELL_TIMEOUT_MS = 120_000;
/** Per captured stream; the command is stopped once either stream exceeds it. */
export const MAX_CAPTURED_OUTPUT_BYTES = 64 * 1024;
/** Lines of one `{!cmd}`'s output that reach the prompt. */
export const MAX_INTERPOLATED_LINES = 200;

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

/**
 * Make text that did not come from the keyboard inert: every `{!` gains a
 * backslash, and when the text opens the prompt (`opensPrompt`) so does a
 * leading `!`. One backslash is added even before existing ones, so
 * {@link unescapeShellSyntax} restores exactly the original text on submit.
 */
export function escapeShellSyntax(text: string, opensPrompt = true): string {
	const escaped = text.replace(/\{!/g, "\\{!");
	return opensPrompt ? escaped.replace(/^(\s*)(\\*)!/, "$1\\$2!") : escaped;
}

/**
 * Composer text that did not come from the keyboard. The editor's own load and
 * paste sanitization (CRs normalized, C0 controls other than tab and newline
 * dropped) runs first, so stripping cannot join `{` and `!` after the escape;
 * then {@link escapeShellSyntax}.
 */
export function inertComposerText(text: string, opensPrompt = true): string {
	const sanitized = text
		.replace(/\r\n?/g, "\n")
		// biome-ignore lint/suspicious/noControlCharactersInRegex: Mirrors the editor's load/paste sanitization.
		.replace(/[\x00-\x08\x0B-\x1F]/g, "");
	return escapeShellSyntax(sanitized, opensPrompt);
}

/**
 * Drop one escaping backslash from every `\{!` and, when `opensPrompt`, from a
 * leading `\!`: the inverse of {@link escapeShellSyntax} for literal text.
 */
export function unescapeShellSyntax(text: string, opensPrompt = true): string {
	const unescaped = text.replace(/\\\{!/g, "{!");
	return opensPrompt ? unescaped.replace(/^(\s*)\\(\\*)!/, "$1$2!") : unescaped;
}

/**
 * Replace every `{!cmd}` span with the command's stdout (trailing newline
 * trimmed, at most {@link MAX_INTERPOLATED_LINES} lines). A failing command is
 * replaced by its stderr so the model sees what went wrong instead of a silent
 * gap; `onResult` lets the caller report it too. Escapes are removed from the
 * literal text only, never from command output. Undefined means `signal`
 * aborted: the prompt must not be sent.
 */
export async function interpolateShellSpans(
	text: string,
	run: (command: string) => Promise<ShellResult>,
	onResult?: (result: ShellResult) => void,
	signal?: AbortSignal,
): Promise<string | undefined> {
	let output = "";
	let cursor = 0;
	for (const span of findShellSpans(text)) {
		output += unescapeShellSyntax(text.slice(cursor, span.start), cursor === 0);
		if (signal?.aborted) return undefined;
		const result = await run(span.command);
		if (signal?.aborted) return undefined;
		onResult?.(result);
		output += interpolatedBody(result);
		cursor = span.end;
	}
	return output + unescapeShellSyntax(text.slice(cursor), cursor === 0);
}

function interpolatedBody(result: ShellResult): string {
	const body =
		result.code === 0 || result.truncated ? result.stdout : result.stderr || result.failure || "";
	const lines = body.replace(/\n+$/, "").split("\n");
	const omitted = lines.length - MAX_INTERPOLATED_LINES;
	if (omitted > 0) {
		lines.length = MAX_INTERPOLATED_LINES;
		lines.push(`[output of \`${result.command}\` truncated: ${omitted} more line(s)]`);
	} else if (result.truncated) {
		lines.push(`[output of \`${result.command}\` truncated at ${MAX_CAPTURED_OUTPUT_BYTES} bytes]`);
	}
	return lines.join("\n");
}

/**
 * Run a command through the shell. Never throws: a spawn failure, a timeout,
 * an output overflow or a cancellation comes back as a result with a `failure`
 * message, because every caller wants to show it rather than handle it.
 *
 * Only captured commands get a default deadline: an interactive command owns
 * the terminal (an editor, a pager, an ssh session) and ends when the user
 * ends it.
 */
export async function runShellCommand(
	command: string,
	options: RunShellOptions = {},
): Promise<ShellResult> {
	const interactive = options.interactive === true;
	const timeoutMs = options.timeoutMs ?? (interactive ? 0 : DEFAULT_SHELL_TIMEOUT_MS);
	const base: ShellResult = { command, code: 0, stdout: "", stderr: "" };
	if (options.signal?.aborted) return { ...base, code: 130, failure: "cancelled" };
	try {
		// Interactive commands must remain in the terminal's process group so
		// full-screen programs and job control keep working.
		const detached = process.platform !== "win32" && !interactive;
		const proc = Bun.spawn([shellBinary(), "-c", command], {
			cwd: options.cwd ?? process.cwd(),
			env: { ...process.env, ...options.env } as Record<string, string>,
			stdin: interactive ? "inherit" : "ignore",
			stdout: interactive ? "inherit" : "pipe",
			stderr: interactive ? "inherit" : "pipe",
			// A shell can leave grandchildren holding the capture pipes open after
			// the shell itself is killed. A private POSIX process group lets the
			// deadline terminate the complete command tree.
			detached,
		});

		let failure: string | undefined;
		let forceKillTimer: ReturnType<typeof setTimeout> | undefined;
		let forceKillPromise: Promise<void> | undefined;
		const stop = (reason: string) => {
			if (failure !== undefined) return;
			failure = reason;
			killShellProcess(proc.pid, proc, detached, "SIGTERM");
			const escalation = Promise.withResolvers<void>();
			forceKillPromise = escalation.promise;
			forceKillTimer = setTimeout(() => {
				killShellProcess(proc.pid, proc, detached, "SIGKILL");
				escalation.resolve();
			}, 250);
			// Captured POSIX commands await this escalation below. Preserve the
			// non-blocking timer behavior everywhere else.
			if (!detached) forceKillTimer.unref?.();
		};
		const timer =
			timeoutMs > 0
				? setTimeout(() => stop(`timed out after ${timeoutMs}ms`), timeoutMs)
				: undefined;
		timer?.unref?.();
		const cancel = () => stop("cancelled");
		options.signal?.addEventListener("abort", cancel, { once: true });

		try {
			const overflow = () =>
				stop(`output exceeded ${MAX_CAPTURED_OUTPUT_BYTES} bytes; command stopped`);
			const [stdout, stderr] = interactive
				? [CAPTURED_NOTHING, CAPTURED_NOTHING]
				: await Promise.all([readCapped(proc.stdout, overflow), readCapped(proc.stderr, overflow)]);
			const code = await proc.exited;
			// A TERM-resistant descendant can redirect stdio, letting the parent
			// exit and close our pipes before the process group is gone. Complete
			// the scheduled escalation before declaring a stopped captured POSIX
			// command finished so no member of the private group escapes.
			if (detached && forceKillPromise) await forceKillPromise;
			clearTimeout(forceKillTimer);

			return {
				...base,
				code,
				stdout: stdout.text,
				stderr: stderr.text,
				failure,
				truncated: stdout.truncated || stderr.truncated || undefined,
			};
		} finally {
			clearTimeout(timer);
			options.signal?.removeEventListener("abort", cancel);
		}
	} catch (error) {
		return {
			...base,
			code: 127,
			failure: error instanceof Error ? error.message : String(error),
		};
	}
}

function killShellProcess(
	pid: number,
	proc: Bun.Subprocess,
	detached: boolean,
	signal: NodeJS.Signals,
): void {
	try {
		if (detached) process.kill(-pid, signal);
		else proc.kill(signal);
	} catch {
		// The command may have exited between the deadline and signal delivery.
	}
}

interface Captured {
	text: string;
	truncated: boolean;
}

const CAPTURED_NOTHING: Captured = { text: "", truncated: false };

/**
 * Read a capture pipe up to {@link MAX_CAPTURED_OUTPUT_BYTES}. Past the cap the
 * reader stops consuming and `overflow` stops the command, so `{!yes}` cannot
 * grow memory until the deadline.
 */
async function readCapped(
	stream: ReadableStream<Uint8Array> | number | undefined,
	overflow: () => void,
): Promise<Captured> {
	if (!stream || typeof stream === "number") return CAPTURED_NOTHING;
	const decoder = new TextDecoder();
	let text = "";
	let size = 0;
	for await (const chunk of stream) {
		const room = MAX_CAPTURED_OUTPUT_BYTES - size;
		if (chunk.byteLength > room) {
			overflow();
			return { text: text + decoder.decode(chunk.subarray(0, room)), truncated: true };
		}
		size += chunk.byteLength;
		text += decoder.decode(chunk, { stream: true });
	}
	return { text: text + decoder.decode(), truncated: false };
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
