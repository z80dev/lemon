/**
 * Where a submitted line goes.
 *
 * Exactly three things can happen to text the user submits:
 *
 *   `/name …`   a slash command runs; nothing reaches the daemon.
 *   `!cmd`      a shell command runs with the TUI suspended; its output is
 *               appended as a notice and nothing reaches the daemon.
 *   anything    `{!cmd}` spans are replaced by their output and the result is
 *               handed to the prompt sink.
 *
 * {@link PromptSink} is the seam P4 owns: `deliver` is the single function
 * between "the user submitted a prompt" and `chat.send`, so queue / steer /
 * redirect / interrupt is implemented by wrapping it, not by editing this file.
 */

import type { CommandHost, CommandRegistry } from "../../commands/index.ts";
import type { ControlPlaneClient } from "../../protocol/client.ts";
import type { ControlPlaneMethods } from "../../protocol/methods.ts";
import {
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
}

/**
 * The prompt seam. P5 ships the direct implementation (`chat.send`); P4 wraps
 * it with the queue.
 */
export interface PromptSink {
	deliver(text: string, options: DeliverOptions): Promise<void>;
}

export interface TerminalSuspender {
	stop(): void;
	start(): void;
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
	/** Test seam. */
	runShell?: typeof runShellCommand;
}

export class CommandController {
	readonly #options: CommandControllerOptions;

	constructor(options: CommandControllerOptions) {
		this.#options = options;
	}

	/** The editor's `onSubmit`. Never throws: failures become notices. */
	async handleSubmit(text: string): Promise<void> {
		const trimmed = text.trim();
		if (trimmed.length === 0) return;
		try {
			if (await this.#options.registry.dispatch(trimmed, this.#context())) return;
			if (isShellLine(trimmed)) {
				await this.runShellLine(shellLineCommand(trimmed));
				return;
			}
			const prompt = await this.#interpolate(text);
			if (prompt.trim().length === 0) {
				this.#options.host.notice("nothing left to send after interpolation", "warning");
				return;
			}
			await this.#options.sink.deliver(prompt, { interpolated: prompt !== text });
		} catch (error) {
			this.#options.host.notice(
				`submit failed: ${error instanceof Error ? error.message : String(error)}`,
				"error",
			);
		}
	}

	/**
	 * Run `!cmd` with the terminal handed over, so an interactive command (an
	 * editor, a pager, anything that reads a key) works. Restoring the TUI is in
	 * a `finally`: a command that dies mid-draw must not leave a dead screen.
	 */
	async runShellLine(command: string): Promise<void> {
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

	/** Replace `{!cmd}` spans, reporting failures without losing the prompt. */
	async #interpolate(text: string): Promise<string> {
		const run = this.#options.runShell ?? runShellCommand;
		return await interpolateShellSpans(
			text,
			(command) => run(command, { cwd: this.#options.cwd }),
			(result) => {
				if (result.code === 0 && !result.failure) return;
				this.#options.host.noticeBlock(formatShellResult(result), "warning");
			},
		);
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
