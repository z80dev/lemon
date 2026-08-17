/**
 * AppShell — the client's root wiring.
 *
 * Flat container order (later phases slot components into the same seams):
 *
 *   banner        welcome + connection state
 *   chat          TranscriptContainer: the blocks, with the native-scrollback
 *                 commit seam (`getNativeScrollbackLiveRegionStart`)
 *   status        panels that sit above the status line (P4 approvals, queue)
 *   statusLine    one line: session, activity, approvals
 *   editor        the prompt
 *
 * Wiring rules this file keeps to, because later phases depend on them:
 *   - controllers own the stores and the UI; components stay dumb
 *   - {@link EventController} is the only writer of store + transcript
 *   - the accumulated delta buffer is the source of truth for a run's final
 *     text (`agent completed.answer` is server-truncated to 500 bytes)
 *   - nothing here calls `process.exit`; `onExit` hands that to main.ts
 */

import { ProcessTerminal, type Terminal } from "@oh-my-pi/pi-tui/terminal";
import { Container, TUI } from "@oh-my-pi/pi-tui/tui";
import { indentBlock, pickNumber } from "./commands/format.ts";
import { type CommandHost, type CommandRegistry, createCommandRegistry } from "./commands/index.ts";
import { editInExternalEditor } from "./external-editor.ts";
import { getGitModeline } from "./git-utils.ts";
import { ControlPlaneClient } from "./protocol/client.ts";
import { ControlPlaneMethods } from "./protocol/methods.ts";
import type { AgentEvent, ChatHistoryMessage } from "./protocol/types.ts";
import { AppStore } from "./store/app-store.ts";
import type { SessionStore } from "./store/session-store.ts";
import type { NoticeLevel } from "./store/transcript-model.ts";
import { CustomEditor } from "./ui/components/custom-editor.ts";
import { ModelPicker } from "./ui/components/model-picker.ts";
import { PickerOverlay } from "./ui/components/pickers.ts";
import { StatusBar, type StatusBarData } from "./ui/components/status-bar.ts";
import { TranscriptContainer } from "./ui/components/transcript-container.ts";
import { ClampedText } from "./ui/components/width-safe.ts";
import { CommandController } from "./ui/controllers/command-controller.ts";
import { EventController } from "./ui/controllers/event-controller.ts";
import { InputController } from "./ui/controllers/input-controller.ts";
import { SelectorController } from "./ui/controllers/selector-controller.ts";
import { getTheme } from "./ui/theme/theme.ts";
import { getEditorTheme } from "./ui/theme/tui-adapters.ts";

export interface AppShellOptions {
	url: string;
	/** Session to talk to. Defaults to a fresh `tui-<timestamp>` key. */
	sessionKey?: string;
	version?: string;
	/** Injection points for tests. */
	client?: ControlPlaneClient;
	terminal?: Terminal;
	tui?: TUI;
	/** Turns off the 30fps reveal; text lands whole. */
	smoothStreaming?: boolean;
	/** Called instead of `process.exit`. */
	onExit?: (code: number) => void;
	/** Working directory for git status and shell escapes. */
	cwd?: string;
	/** Test seam for the status bar's git poll. */
	readBranch?: (cwd: string) => Promise<string | null>;
}

export function defaultSessionKey(now: Date = new Date()): string {
	return `tui-${now.toISOString().replace(/[-:.]/g, "").slice(0, 15)}`;
}

export class AppShell {
	readonly tui: TUI;
	readonly client: ControlPlaneClient;
	readonly methods: ControlPlaneMethods;
	readonly store: AppStore;
	readonly events: EventController;

	readonly commands: CommandRegistry;
	readonly selectors: SelectorController;
	readonly commandController: CommandController;
	readonly input: InputController;

	readonly bannerContainer = new Container();
	readonly chatContainer = new TranscriptContainer();
	readonly statusContainer = new Container();
	readonly statusLineContainer = new Container();
	readonly editorContainer = new Container();

	// Clamped: pi-tui keeps a Text's horizontal padding at every width, so a very
	// narrow terminal would otherwise get chrome rows wider than the frame.
	readonly #banner = new ClampedText("", 1, 0);
	readonly #connectionLine = new ClampedText("", 1, 0);
	readonly #statusBar: StatusBar;
	readonly #editor: CustomEditor;
	readonly #modelPicker: ModelPicker;
	readonly #host: CommandHost;

	readonly #version: string;
	readonly #onExit: ((code: number) => void) | undefined;
	readonly #cwd: string;

	#disposers: Array<() => void> = [];
	#started = false;

	constructor(options: AppShellOptions) {
		this.#version = options.version ?? "dev";
		this.#onExit = options.onExit;
		this.#cwd = options.cwd ?? process.cwd();
		this.client = options.client ?? new ControlPlaneClient({ url: options.url });
		this.methods = new ControlPlaneMethods(this.client);
		this.tui = options.tui ?? new TUI(options.terminal ?? new ProcessTerminal());
		this.store = new AppStore(options.sessionKey ?? defaultSessionKey());
		// Editor construction needs a theme: pi-tui ships no defaults.
		this.#editor = new CustomEditor({
			theme: getEditorTheme(),
			onSubmit: (text) => this.submit(text),
			onAbort: () => this.#abortActiveRun(),
			onQuit: (code) => this.requestExit(code),
			onExternalEdit: () => this.openExternalEditor(),
			notice: (text, level) => this.events.notice(text, level),
			requestRender: () => this.tui.requestRender(),
		});
		const smooth = options.smoothStreaming !== false;
		this.events = new EventController({
			client: this.client,
			store: this.store,
			tui: this.tui,
			transcript: this.chatContainer,
			onStatusChanged: () => this.#renderStatus(),
			smoothStreaming: () => smooth,
		});

		this.#statusBar = new StatusBar({
			data: () => this.statusData(),
			cwd: this.#cwd,
			readBranch: options.readBranch ?? getGitModeline,
			onChange: () => this.tui.requestRender(),
		});
		this.selectors = new SelectorController({
			tui: this.tui,
			defaultFocus: () => this.#editor,
		});
		this.#modelPicker = new ModelPicker({
			store: this.store,
			methods: this.methods,
			session: () => this.store.focused,
			notice: (text, level) => this.events.notice(text, level),
			refreshStatus: () => this.#renderStatus(),
			present: (overlay) => this.selectors.open(overlay),
			repaint: () => this.selectors.repaint(),
		});
		this.#host = this.#buildHost();
		this.commands = createCommandRegistry({
			openExternalEditor: () => this.openExternalEditor(),
		});
		this.commandController = new CommandController({
			registry: this.commands,
			store: this.store,
			methods: this.methods,
			client: this.client,
			host: this.#host,
			sink: { deliver: (text) => this.sendPrompt(text) },
			tui: this.tui,
			cwd: this.#cwd,
		});
		this.input = new InputController({
			tui: this.tui,
			hasOverlay: () => this.selectors.isOpen,
			openModelPicker: () => this.#modelPicker.open(),
			openExternalEditor: () => this.openExternalEditor(),
			clearTranscript: () => this.#host.clearTranscript(),
			notice: (text) => this.events.notice(text),
		});
	}

	get sessionKey(): string {
		return this.store.focusedKey;
	}

	get session(): SessionStore {
		return this.store.focused;
	}

	get editor(): CustomEditor {
		return this.#editor;
	}

	get statusBar(): StatusBar {
		return this.#statusBar;
	}

	/** The seam commands use. Exposed so tests can drive a command directly. */
	get host(): CommandHost {
		return this.#host;
	}

	/** Build the UI, start rendering, and connect. */
	async start(): Promise<void> {
		if (this.#started) return;
		this.#started = true;
		this.#buildUi();
		this.input.attach();
		this.events.attach();
		this.#disposers.push(
			this.client.events.on("state", () => this.#renderConnection()),
			this.client.events.on("queued", () => this.#renderConnection()),
			this.client.events.on("queue-flushed", () => this.#renderConnection()),
			// A finished run is the moment the branch and the token budget can
			// both have moved, and the only one worth spending a request on.
			this.client.events.on("agent", (event: AgentEvent) => {
				if (event?.type !== "completed") return;
				void this.#statusBar.refreshBranch();
				void this.refreshUsage();
			}),
			this.store.events.on("mode-changed", () => this.#renderStatus()),
			() => this.#statusBar.dispose(),
			() => this.selectors.dispose(),
			() => this.input.dispose(),
		);
		this.tui.start();
		this.#statusBar.start();
		this.#renderStatus();
		try {
			await this.client.connect();
		} catch (error) {
			// The socket keeps retrying in the background; just say so.
			this.events.notice(`connection failed: ${describeError(error)}`, "error");
		}
	}

	stop(): void {
		for (const dispose of this.#disposers.splice(0)) dispose();
		this.events.dispose();
		this.client.close();
		if (this.#started) this.tui.stop();
		this.#started = false;
	}

	// -- ui -----------------------------------------------------------------

	#buildUi(): void {
		const theme = getTheme();
		this.#banner.setText(
			`${theme.fg("bannerTitle", "lemon")} ${theme.fg("bannerSubtitle", `tui ${this.#version}`)}  ${theme.fg(
				"dim",
				"/help · Ctrl+O model · Ctrl+G editor · Ctrl+C abort/quit",
			)}`,
		);
		this.bannerContainer.addChild(this.#banner);
		this.bannerContainer.addChild(this.#connectionLine);
		this.statusLineContainer.addChild(this.#statusBar);

		// Slash-command and file-path completion in the prompt.
		this.#editor.setCommands(
			this.commands.list().map((command) => ({
				name: command.name,
				description: command.summary,
				argumentHint: command.usage,
			})),
			this.#cwd,
		);
		this.editorContainer.addChild(this.#editor);

		this.tui.addChild(this.bannerContainer);
		this.tui.addChild(this.chatContainer);
		this.tui.addChild(this.statusContainer);
		this.tui.addChild(this.statusLineContainer);
		this.tui.addChild(this.editorContainer);
		this.tui.setFocus(this.#editor);
		this.#renderConnection();
	}

	#renderConnection(): void {
		const theme = getTheme();
		const state = this.client.state;
		const slot = state === "online" ? "success" : state === "offline" ? "error" : "warning";
		const queued = this.client.queued.length;
		const suffix = queued > 0 ? theme.fg("dim", `  (${queued} queued)`) : "";
		this.#connectionLine.setText(
			`${theme.fg("dim", this.client.url)}  ${theme.fg(slot, state)}${suffix}`,
		);
		this.tui.requestRender();
	}

	#renderStatus(): void {
		this.#statusBar.invalidate();
		this.tui.requestRender();
	}

	/** Everything the status bar shows, read fresh on each render. */
	statusData(): StatusBarData {
		const session = this.store.focused;
		return {
			sessionKey: session.key,
			model: session.model,
			contextTokens: contextTokensFrom(this.store.usage),
			contextWindow: contextWindowFor(this.store, session.model),
			sessionCount: this.store.sessions.size,
			busy: session.busy,
			unread: this.store.totalUnread(),
			approvals: this.store.pendingApprovals,
			connection: this.client.state,
			mode: this.store.submissionMode,
			thinking: session.thinkingLevel,
			engine: session.engine,
			queued: this.client.queued.length,
		};
	}

	/** Refresh the usage numbers behind the context gauge. Never throws. */
	async refreshUsage(): Promise<void> {
		if (!this.methods.supports("usage.status")) return;
		try {
			this.store.usage = (await this.methods.usageStatus()) as Record<string, unknown>;
			this.#renderStatus();
		} catch {
			// The gauge keeps its last known numbers; this is not worth a notice.
		}
	}

	// -- input --------------------------------------------------------------

	/** Ctrl+C's first job. Returns true when there was a run to stop. */
	#abortActiveRun(): boolean {
		const session = this.store.focused;
		const runId = session.activeRunId;
		if (!runId) return false;
		this.events.notice("aborting…");
		void this.methods
			.chatAbort({ runId, sessionKey: session.key })
			.catch((error) => this.events.notice(`abort failed: ${describeError(error)}`, "error"));
		return true;
	}

	/** Ctrl+G / `/editor`: hand the draft to $EDITOR and take back what returns. */
	async openExternalEditor(): Promise<void> {
		const draft = this.#editor.getExpandedText();
		try {
			const edited = await editInExternalEditor(draft, { tui: this.tui });
			if (edited === null) return;
			this.#editor.setText(edited);
			this.tui.requestRender(true);
		} catch (error) {
			this.events.notice(`editor: ${describeError(error)}`, "error");
		}
	}

	requestExit(code: number): void {
		this.stop();
		this.#onExit?.(code);
	}

	// -- submit -------------------------------------------------------------

	/**
	 * Everything the user submits enters here — from the editor, from a test, or
	 * from a rerun. Slash commands and shell escapes are peeled off first; what
	 * remains reaches {@link sendPrompt}.
	 */
	async submit(value: string): Promise<void> {
		await this.commandController.handleSubmit(value);
	}

	/**
	 * The prompt sink: echo the user's text and send it.
	 *
	 * P4 wraps this (queue / steer / interrupt) by replacing the `sink` handed to
	 * the {@link CommandController}; the signature is the contract.
	 */
	async sendPrompt(text: string): Promise<void> {
		const prompt = text.trim();
		if (prompt.length === 0) return;
		const session = this.store.focused;
		this.events.addUserBlock(prompt, session);
		this.#editor.disarm();

		try {
			const result = await this.methods.chatSend({ sessionKey: session.key, prompt });
			if (result?.runId) this.events.noteRunStarted(result.runId, session);
		} catch (error) {
			this.events.notice(`send failed: ${describeError(error)}`, "error", session);
		}
	}

	// -- the command host ----------------------------------------------------

	#buildHost(): CommandHost {
		return {
			notice: (text: string, level?: NoticeLevel) => this.events.notice(text, level),
			noticeBlock: (lines: string[], level?: NoticeLevel) =>
				this.events.notice(indentBlock(lines), level),
			clearTranscript: () => this.#clearTranscript(),
			requestExit: (code: number) => this.requestExit(code),
			reconnect: () => this.client.reconnect(),
			refreshStatus: () => this.#renderStatus(),
			getDraft: () => this.#editor.getExpandedText(),
			setDraft: (text: string) => {
				this.#editor.setText(text);
				this.tui.requestRender();
			},
			openPicker: (spec) => {
				const overlay = new PickerOverlay({
					title: spec.title,
					items: spec.items.map((item) => ({
						value: item.value,
						label: item.label,
						description: item.description,
					})),
					footer: spec.footer,
					onSelect: (item) => {
						this.selectors.close();
						void spec.onSelect(item);
					},
					onCancel: () => {
						this.selectors.close();
						spec.onCancel?.();
					},
				});
				this.selectors.open(overlay);
			},
			closeOverlay: () => this.selectors.close(),
			frameLog: () => this.client.recentFrames(),
			replayHistory: (messages: ChatHistoryMessage[]) => this.#replayHistory(messages),
			openModelPicker: () => this.#modelPicker.open(),
			themeChanged: () => {
				this.tui.invalidate();
				this.tui.requestRender(true);
			},
		};
	}

	/**
	 * Drop the transcript. This is one of the two sanctioned scrollback-clearing
	 * paths (the other is a session switch): the blocks the terminal is holding
	 * are gone from our model, so leaving them in native history would show the
	 * user a transcript the client can no longer reason about.
	 */
	#clearTranscript(): void {
		const session = this.store.focused;
		session.blocks.length = 0;
		session.byActionId.clear();
		this.events.rebuildFocused();
		this.tui.requestRender(true, { clearScrollback: true });
	}

	/**
	 * Replay stored history into the transcript. Each assistant message becomes a
	 * finalized block under a synthetic run id, so nothing later tries to stream
	 * into it.
	 */
	#replayHistory(messages: ChatHistoryMessage[]): void {
		const session = this.store.focused;
		for (const message of messages) {
			const at = message.timestampMs ?? Date.now();
			const content = message.content ?? "";
			if (message.role === "user") {
				session.addUser(content, at);
				continue;
			}
			const runId = `history:${message.id}`;
			session.ensureAssistant(runId, at);
			session.appendDelta(runId, Number.NaN, content);
			session.finalizeRun(runId, { ok: true });
		}
		this.events.rebuildFocused();
		this.tui.requestRender(true, { clearScrollback: true });
	}
}

/**
 * Tokens for the context gauge.
 *
 * `usage.status` reports today's totals rather than the live context window, so
 * an explicit context field is preferred wherever a daemon provides one and the
 * token totals are the documented fallback. Either way the gauge is a budget
 * indicator, which is what it is labelled as.
 */
export function contextTokensFrom(usage: Record<string, unknown> | undefined): number | undefined {
	if (!usage) return undefined;
	const explicit = pickNumber(usage, "context.tokens", "contextTokens", "summary.contextTokens");
	if (explicit !== undefined) return explicit;
	const total = pickNumber(usage, "summary.totalTokens");
	if (total !== undefined) return total;
	const input = pickNumber(usage, "tokens.input") ?? 0;
	const output = pickNumber(usage, "tokens.output") ?? 0;
	const sum = input + output;
	return sum > 0 ? sum : undefined;
}

/** The context window of the session's model, from the `models.list` cache. */
export function contextWindowFor(store: AppStore, model: string | undefined): number | undefined {
	if (!model) return undefined;
	for (const entry of store.models ?? []) {
		if (entry.id === model || entry.id === model.split(":").pop()) {
			const window = pickNumber(entry, "contextWindow");
			if (window !== undefined) return window;
		}
	}
	return undefined;
}

function describeError(error: unknown): string {
	if (error instanceof Error) return error.message;
	return String(error);
}
