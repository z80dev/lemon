/**
 * Where a submitted line goes.
 *
 * Exactly three things can happen to text the user submits:
 *
 *   `/name …`   a slash command runs; nothing reaches the daemon.
 *   `!cmd`      a shell command runs with the TUI suspended; its output is
 *               appended as a notice and nothing reaches the daemon.
 *   anything    `{!cmd}` spans are replaced by their output and the result is
 *               handed to the prompt sink. Escape cancels an in-flight
 *               interpolation and the prompt goes back to the composer.
 *
 * Nothing reaches the shell until the user confirms the exact command text
 * ({@link CommandControllerOptions.confirmShell}). Shell intent is classified
 * here, on the final text after composer markup was removed, so no edit,
 * completion, paste, recall or markup step can smuggle a command past that
 * confirmation. Escaping non-typed text (`escapeShellSyntax` in shell.ts) only
 * keeps pasted and restored text from asking at all.
 *
 * {@link PromptSink} is the seam P4 owns: `deliver` is the single function
 * between "the user submitted a prompt" and `chat.send`, so queue / steer /
 * redirect / interrupt is implemented by wrapping it, not by editing this file.
 */

import type { CommandHost, CommandRegistry } from "../../commands/index.ts";
import type { SubmissionDisposition } from "../../composer/drafts.ts";
import type { ControlPlaneClient } from "../../protocol/client.ts";
import type { ControlPlaneMethods } from "../../protocol/methods.ts";
import {
	findShellSpans,
	formatShellResult,
	interpolateShellSpans,
	isShellLine,
	runShellCommand,
	type ShellResult,
	shellLineCommand,
} from "../../shell.ts";
import type { AppStore, SubmissionMode } from "../../store/app-store.ts";

export interface DeliverOptions {
	/** What to do when a run is already in flight. Defaults to the app setting. */
	mode?: SubmissionMode;
	/** True when the text came out of `{!cmd}` interpolation. */
	interpolated?: boolean;
	/** Command recovery sends must remain drafts rather than park an offline RPC. */
	queueIfOffline?: boolean;
}

/**
 * The prompt seam. P5 ships the direct implementation (`chat.send`); P4 wraps
 * it with the queue.
 */
export interface PromptSink {
	deliver(text: string, options: DeliverOptions): Promise<SubmissionDisposition>;
}

export interface TerminalSuspender {
	stop(): void;
	start(): void;
}

/** What the confirmation shows: every command exactly as it would run. */
export interface ShellConfirmRequest {
	/** `!cmd` owns the terminal; `{!cmd}` output is spliced into the prompt. */
	kind: "interactive" | "captured";
	commands: readonly string[];
}

export interface CommandControllerOptions {
	registry: CommandRegistry;
	store: AppStore;
	methods: ControlPlaneMethods;
	client: ControlPlaneClient;
	host: CommandHost;
	sink: PromptSink;
	/** Suspended around interactive `!cmd`. */
	tui?: TerminalSuspender;
	cwd?: string;
	/**
	 * Ask the user to run exactly these commands; true only on an explicit
	 * "Run". Without it no shell escape ever runs.
	 */
	confirmShell?: (request: ShellConfirmRequest) => Promise<boolean>;
	/** Test seam. */
	runShell?: typeof runShellCommand;
}

export class CommandController {
	readonly #options: CommandControllerOptions;
	readonly #interpolations = new Set<AbortController>();

	constructor(options: CommandControllerOptions) {
		this.#options = options;
	}

	/** Stop every in-flight `{!cmd}` interpolation. False when none is running. */
	cancelInterpolation(): boolean {
		if (this.#interpolations.size === 0) return false;
		for (const interpolation of this.#interpolations) interpolation.abort();
		this.#interpolations.clear();
		return true;
	}

	/** The editor's `onSubmit`. Never throws: failures become notices. */
	async handleSubmit(text: string): Promise<SubmissionDisposition> {
		const trimmed = text.trim();
		if (trimmed.length === 0) return "rejected";
		try {
			if (await this.#options.registry.dispatch(trimmed, this.#context())) return "accepted";
			if (isShellLine(trimmed)) {
				const command = shellLineCommand(trimmed);
				if (!(await this.#confirm({ kind: "interactive", commands: [command] }))) {
					return "rejected";
				}
				await this.#runShellLine(command);
				return "accepted";
			}
			const commands = findShellSpans(text).map((span) => span.command);
			if (commands.length > 0 && !(await this.#confirm({ kind: "captured", commands }))) {
				return "rejected";
			}
			const prompt = await this.#interpolate(text);
			if (prompt === undefined) {
				this.#options.host.notice("shell interpolation cancelled; nothing was sent", "warning");
				return "rejected";
			}
			if (prompt.trim().length === 0) {
				this.#options.host.notice("nothing left to send after interpolation", "warning");
				return "rejected";
			}
			return await this.#options.sink.deliver(prompt, { interpolated: prompt !== text });
		} catch (error) {
			this.#options.host.notice(
				`submit failed: ${error instanceof Error ? error.message : String(error)}`,
				"error",
			);
			return "rejected";
		}
	}

	/** False unless the user explicitly chose to run exactly `request.commands`. */
	async #confirm(request: ShellConfirmRequest): Promise<boolean> {
		const confirm = this.#options.confirmShell;
		if (!confirm) {
			this.#options.host.notice(
				"shell escapes need a confirmation this client cannot show; nothing ran",
				"warning",
			);
			return false;
		}
		if (await confirm(request)) return true;
		this.#options.host.notice("shell command not run; the prompt is back in the composer");
		return false;
	}

	/**
	 * Run `!cmd` with the terminal handed over, so an interactive command (an
	 * editor, a pager, anything that reads a key) works. Restoring the TUI is in
	 * a `finally`: a command that dies mid-draw must not leave a dead screen.
	 */
	async #runShellLine(command: string): Promise<void> {
		const run = this.#options.runShell ?? runShellCommand;
		const tui = this.#options.tui;
		let result: ShellResult;
		tui?.stop();
		try {
			result = await run(command, { cwd: this.#options.cwd, interactive: true });
		} finally {
			tui?.start();
		}
		// Interactive output went straight to the terminal and is gone from our
		// frame, so the transcript records the command and how it ended.
		const status = result.failure ?? (result.code === 0 ? "ok" : `exit ${result.code}`);
		this.#options.host.noticeBlock(
			[`$ ${command}`, status],
			result.code === 0 ? "info" : "warning",
		);
	}

	/**
	 * Replace `{!cmd}` spans, reporting failures without losing the prompt.
	 * Undefined when {@link cancelInterpolation} stopped it.
	 */
	async #interpolate(text: string): Promise<string | undefined> {
		const run = this.#options.runShell ?? runShellCommand;
		const interpolation = new AbortController();
		this.#interpolations.add(interpolation);
		try {
			return await interpolateShellSpans(
				text,
				(command) => run(command, { cwd: this.#options.cwd, signal: interpolation.signal }),
				(result) => {
					if (result.code === 0 && !result.failure) return;
					this.#options.host.noticeBlock(formatShellResult(result), "warning");
				},
				interpolation.signal,
			);
		} finally {
			this.#interpolations.delete(interpolation);
		}
	}

	#context() {
		return {
			store: this.#options.store,
			cwd: this.#options.cwd,
			session: this.#options.store.focused,
			methods: this.#options.methods,
			client: this.#options.client,
			ui: this.#options.host,
		};
	}
}
