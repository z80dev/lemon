/**
 * Slash-command registry.
 *
 * A command is data plus a `run`: the registry owns lookup, availability and
 * help rendering, and nothing else in the client knows the command list. The
 * availability gate is the same one the protocol layer uses — a command whose
 * backing method is missing from `hello-ok.features.methods` is listed as
 * disabled and refuses to run, rather than round-tripping to a METHOD_NOT_FOUND.
 *
 * Commands never touch pi-tui. Everything they need from the UI arrives through
 * {@link CommandHost}, whose optional members are the seams later phases fill
 * in (P4 the queue panel, P6 the session switcher); a command that needs a hook
 * the host has not implemented says so in a notice instead of throwing.
 */

import type { ControlPlaneClient } from "../protocol/client.ts";
import type { ControlPlaneMethods, MethodName } from "../protocol/methods.ts";
import type { ChatHistoryMessage } from "../protocol/types.ts";
import type { AppStore, SubmissionMode } from "../store/app-store.ts";
import type { SessionStore } from "../store/session-store.ts";
import type { NoticeLevel } from "../store/transcript-model.ts";
import type { ThemePreference } from "../ui/theme/appearance.ts";

/** One entry in a picker overlay opened from a command. */
export interface PickerChoice {
	value: string;
	label: string;
	description?: string;
}

export interface PickerSpec {
	title: string;
	items: PickerChoice[];
	/** Hint line under the list. */
	footer?: string;
	onSelect: (choice: PickerChoice) => void | Promise<void>;
	onCancel?: () => void;
}

export interface MultiPickerSpec {
	title: string;
	items: PickerChoice[];
	selectedValues?: string[];
	disabledValues?: string[];
	footer?: string;
	onConfirm: (choices: PickerChoice[]) => void | Promise<void>;
	onCancel?: () => void;
}

/**
 * The UI surface commands are allowed to touch.
 *
 * Required members exist from P5 on. Optional ones are later phases' seams:
 * check for them before calling, and tell the user when they are missing.
 */
export interface CommandHost {
	/** Append a notice block to the focused transcript. */
	notice(text: string, level?: NoticeLevel): void;
	/** Append a multi-line notice; continuation lines are indented for reading. */
	noticeBlock(lines: string[], level?: NoticeLevel): void;
	/** Drop every transcript block and clear native scrollback. */
	clearTranscript(): void;
	requestExit(code: number): void;
	/** Force a reconnect of the control-plane socket. */
	reconnect(): void;
	/** Recompute the status bar (model/context/branch inputs changed). */
	refreshStatus(): void;
	/** Current editor text. */
	getDraft(): string;
	setDraft(text: string): void;
	/** Open a single-stage picker overlay. Draft-preserving. */
	openPicker(spec: PickerSpec): void;
	/** Open a filterable checkbox picker. Space toggles; enter confirms. */
	openMultiPicker(spec: MultiPickerSpec): void;
	/** Close whatever overlay is open. */
	closeOverlay(): void;
	/** Recent protocol frames, newest last (for `/debug`). */
	frameLog(): readonly string[];
	/** Replay server-side history into the transcript (`/resume`). */
	replayHistory(messages: ChatHistoryMessage[]): void;
	/** The Ctrl+X session switcher. */
	openSessionSwitcher?(): void;
	/** Focus another session, hydrating it if cold. */
	switchSession?(sessionKey: string): void | Promise<void>;
	/** Remember one server-confirmed profile route and open its canonical chat. */
	openProfile?(profileId: string, sessionKey: string): void | Promise<void>;
	/** Forget a route after the server deletes that profile. */
	forgetProfile?(profileId: string, sessionKey: string): void;
	/** Mint a session (optionally keyed, optionally with a first prompt). */
	createSession?(sessionKey?: string, prompt?: string): void | Promise<void>;
	/** Drop a session locally and server-side, after confirming. */
	closeSession?(sessionKey: string): void | Promise<void>;
	/** Forget a session locally after the daemon has verified lifecycle deletion. */
	forgetDeletedSession?(sessionKey: string): void | Promise<void>;
	/** Forget a session's transcript locally without touching the daemon. */
	resetSession?(sessionKey: string): void;
	/** Focus the pending-queue panel (`/queue`, Ctrl+Q). */
	focusQueue?(): boolean;
	/** Deliver a command-supplied prompt through the normal submission state machine. */
	deliverPrompt?(text: string, mode: SubmissionMode): void | Promise<void>;
	/** The client-side queue for the focused session, for `/queue` to describe. */
	queuedPrompts?(): readonly string[];
	/**
	 * Answer a pending approval. Routed through the host so the panel, the store
	 * and the transcript record all learn about it — a command that called
	 * `exec.approval.resolve` itself would leave the panel on screen.
	 */
	resolveApproval?(approvalId: string, decision: string): Promise<void>;
	/** Render a user-stopped run as interrupted (partial text kept). */
	markInterrupted?(runId: string): void;
	/** One line per global key, appended to `/help` by the host that owns them. */
	keyHelp?(): string[];
	/** Re-render everything after a theme swap. */
	themeChanged?(): void;
	/** Install a theme preference; returns the appearance now on screen. */
	setThemePreference?(preference: ThemePreference): "dark" | "light";
	/** What `/theme` reports with no argument. */
	themeStatus?(): { preference: ThemePreference; appearance: "dark" | "light"; source?: string };
	/** The two-stage model picker (Ctrl+O), when the UI has one mounted. */
	openModelPicker?(): void | Promise<void>;
}

export interface CommandContext {
	store: AppStore;
	/** The TUI's resolved project working directory. */
	cwd?: string;
	/** The session the command applies to: whatever is focused at dispatch. */
	session: SessionStore;
	methods: ControlPlaneMethods;
	client: ControlPlaneClient;
	ui: CommandHost;
	registry: CommandRegistry;
	/** The command name as typed (an alias stays the alias). */
	name: string;
	/** Everything after the command name, verbatim and untrimmed of inner space. */
	rest: string;
}

export interface SlashCommand {
	name: string;
	aliases?: string[];
	summary: string;
	/** Argument syntax, without the leading command name. */
	usage?: string;
	/** Grouping for `/help`. */
	group?: string;
	/**
	 * Methods the command cannot work without. Missing ones disable it.
	 * Optional degradations (a nicer render when a method exists) are checked
	 * inside `run` instead.
	 */
	methods?: MethodName[];
	/**
	 * Extra availability rule. Return a string to explain why the command is
	 * unavailable; true/undefined means available.
	 */
	availableWhen?(ctx: CommandContext): boolean | string;
	run(ctx: CommandContext, argv: string[]): void | Promise<void>;
}

export interface Availability {
	available: boolean;
	/** Present when unavailable. */
	reason?: string;
}

/** A parsed `/name args` line. */
export interface ParsedCommandLine {
	name: string;
	argv: string[];
	rest: string;
}

/**
 * Split a submitted line into a command and its arguments.
 * Returns null when the line is not a slash command — a bare `/` or a path like
 * `/usr/bin/env` (leading slash followed by a `/`) stays ordinary prompt text.
 */
export function parseCommandLine(line: string): ParsedCommandLine | null {
	const text = line.trimStart();
	if (!text.startsWith("/")) return null;
	const body = text.slice(1);
	if (body.length === 0) return null;
	const match = body.match(/^([A-Za-z][\w-]*)(?:\s+([\s\S]*))?$/);
	if (!match) return null;
	const rest = (match[2] ?? "").trim();
	return { name: match[1].toLowerCase(), argv: splitArgs(rest), rest };
}

/** Whitespace split that keeps quoted runs together. */
export function splitArgs(text: string): string[] {
	const argv: string[] = [];
	const pattern = /"([^"]*)"|'([^']*)'|(\S+)/g;
	let match = pattern.exec(text);
	while (match !== null) {
		argv.push(match[1] ?? match[2] ?? match[3] ?? "");
		match = pattern.exec(text);
	}
	return argv;
}

export class CommandRegistry {
	readonly #byName = new Map<string, SlashCommand>();
	readonly #commands: SlashCommand[] = [];

	register(command: SlashCommand): this {
		if (this.#byName.has(command.name)) {
			throw new Error(`duplicate command: /${command.name}`);
		}
		this.#byName.set(command.name, command);
		for (const alias of command.aliases ?? []) {
			if (this.#byName.has(alias)) throw new Error(`duplicate command alias: /${alias}`);
			this.#byName.set(alias, command);
		}
		this.#commands.push(command);
		return this;
	}

	registerAll(commands: Iterable<SlashCommand>): this {
		for (const command of commands) this.register(command);
		return this;
	}

	get(name: string): SlashCommand | undefined {
		return this.#byName.get(name.toLowerCase());
	}

	has(name: string): boolean {
		return this.#byName.has(name.toLowerCase());
	}

	/** Registration order, which is the order `/help` prints. */
	list(): readonly SlashCommand[] {
		return this.#commands;
	}

	/** Every name and alias, sorted — the autocomplete corpus. */
	names(): string[] {
		return [...this.#byName.keys()].sort();
	}

	availability(command: SlashCommand, ctx: CommandContext): Availability {
		for (const method of command.methods ?? []) {
			if (!ctx.methods.supports(method)) {
				return { available: false, reason: `daemon does not support ${method}` };
			}
		}
		const extra = command.availableWhen?.(ctx);
		if (extra === false) return { available: false, reason: "unavailable" };
		if (typeof extra === "string") return { available: false, reason: extra };
		return { available: true };
	}

	/**
	 * Run the command on `line`. Returns false when the line is not a command at
	 * all, so the caller can send it as a prompt. Unknown commands and failures
	 * are reported through the host and still count as handled.
	 */
	async dispatch(line: string, ctx: Omit<CommandContext, "name" | "rest" | "registry">) {
		const parsed = parseCommandLine(line);
		if (!parsed) return false;
		const command = this.get(parsed.name);
		const full: CommandContext = {
			...ctx,
			registry: this,
			name: parsed.name,
			rest: parsed.rest,
		};
		if (!command) {
			const suggestion = this.#closest(parsed.name);
			ctx.ui.notice(
				`unknown command /${parsed.name}${suggestion ? ` — did you mean /${suggestion}?` : ""}`,
				"error",
			);
			return true;
		}
		const availability = this.availability(command, full);
		if (!availability.available) {
			ctx.ui.notice(`/${command.name} is unavailable: ${availability.reason}`, "warning");
			return true;
		}
		try {
			await command.run(full, parsed.argv);
		} catch (error) {
			ctx.ui.notice(`/${command.name} failed: ${describeError(error)}`, "error");
		}
		return true;
	}

	/** `/help` body: one line per command, disabled ones annotated. */
	renderHelp(ctx: CommandContext, filter?: string): string[] {
		const wanted = filter?.trim().toLowerCase().replace(/^\//, "");
		if (wanted) {
			const command = this.get(wanted);
			if (!command) return [`no such command: /${wanted}`];
			return this.#renderOne(command, ctx);
		}
		const lines: string[] = ["commands"];
		let group: string | undefined;
		for (const command of this.#commands) {
			if (command.group !== group) {
				group = command.group;
				if (group) lines.push(`${group}:`);
			}
			const availability = this.availability(command, ctx);
			const usage = command.usage ? ` ${command.usage}` : "";
			const suffix = availability.available ? "" : `  (disabled: ${availability.reason})`;
			lines.push(`  /${command.name}${usage} — ${command.summary}${suffix}`);
		}
		lines.push("");
		lines.push("!cmd runs a shell command · {!cmd} interpolates its output into a prompt");
		return lines;
	}

	#renderOne(command: SlashCommand, ctx: CommandContext): string[] {
		const availability = this.availability(command, ctx);
		const lines = [`/${command.name}${command.usage ? ` ${command.usage}` : ""}`, command.summary];
		if (command.aliases?.length)
			lines.push(`aliases: ${command.aliases.map((a) => `/${a}`).join(", ")}`);
		if (command.methods?.length) lines.push(`methods: ${command.methods.join(", ")}`);
		if (!availability.available) lines.push(`disabled: ${availability.reason}`);
		return lines;
	}

	/** Cheap "did you mean": shared prefix first, then substring. */
	#closest(name: string): string | undefined {
		const names = this.names();
		return (
			names.find((candidate) => candidate.startsWith(name.slice(0, 3)) && name.length >= 3) ??
			names.find((candidate) => candidate.includes(name) || name.includes(candidate))
		);
	}
}

export function describeError(error: unknown): string {
	if (error instanceof Error) return error.message;
	return String(error);
}

/** Submission modes `/mode` sets and Alt+Enter cycles. */
export const SUBMISSION_MODES: readonly SubmissionMode[] = [
	"queue",
	"steer",
	"redirect",
	"interrupt",
];
