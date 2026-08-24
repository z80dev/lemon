/**
 * AppShell — the client's root wiring.
 *
 * Flat container order (later phases slot components into the same seams):
 *
 *   banner        welcome + connection state
 *   chat          TranscriptContainer: the blocks, with the native-scrollback
 *                 commit seam (`getNativeScrollbackLiveRegionStart`)
 *   queue         the editable backlog, when there is one
 *   approval      the decision panel, when a tool is waiting
 *   status        spare slot above the status line
 *   statusLine    one line: session, activity, approvals
 *   editor        the prompt
 *
 * The two panels sit *below* the transcript on purpose: everything under the
 * transcript's live region is repainted every frame, so a panel that appears,
 * grows and vanishes can never strand a row in the terminal's own scrollback.
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
import { indentBlock, pickNumber, pickString } from "./commands/format.ts";
import { type CommandHost, type CommandRegistry, createCommandRegistry } from "./commands/index.ts";
import { contextWindowFromCache } from "./commands/model.ts";
import { SUBMISSION_MODES } from "./commands/registry.ts";
import { editInExternalEditor } from "./external-editor.ts";
import { getGitModeline } from "./git-utils.ts";
import { ControlPlaneClient } from "./protocol/client.ts";
import { ControlPlaneMethods, METHOD } from "./protocol/methods.ts";
import type {
	AgentCompletedEvent,
	AgentEvent,
	ChatHistoryMessage,
	QueueMode,
} from "./protocol/types.ts";
import { AppStore, type SubmissionMode } from "./store/app-store.ts";
import type { QueueItem } from "./store/queue-store.ts";
import type { SessionStore } from "./store/session-store.ts";
import type { NoticeLevel } from "./store/transcript-model.ts";
import { CustomEditor } from "./ui/components/custom-editor.ts";
import { ModelPicker } from "./ui/components/model-picker.ts";
import { PickerOverlay } from "./ui/components/pickers.ts";
import { QueuePanelComponent } from "./ui/components/queue-panel.ts";
import { SessionSwitcher } from "./ui/components/session-switcher.ts";
import { type ContextSource, StatusBar, type StatusBarData } from "./ui/components/status-bar.ts";
import { TranscriptContainer } from "./ui/components/transcript-container.ts";
import { ClampedText } from "./ui/components/width-safe.ts";
import { ApprovalController } from "./ui/controllers/approval-controller.ts";
import { CommandController, type DeliverOptions } from "./ui/controllers/command-controller.ts";
import { EventController } from "./ui/controllers/event-controller.ts";
import { InputController } from "./ui/controllers/input-controller.ts";
import { SelectorController } from "./ui/controllers/selector-controller.ts";
import {
	type ConfirmSpec,
	SessionController,
	synthesizeHistory,
} from "./ui/controllers/session-controller.ts";
import { AppearanceController, type ThemePreference } from "./ui/theme/appearance.ts";
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
	/**
	 * What `main.ts` resolved from env + config. `auto` keeps following the
	 * terminal's OSC 11 reports for as long as the client runs.
	 */
	themePreference?: ThemePreference;
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
	readonly approvals: ApprovalController;
	readonly sessions: SessionController;
	readonly appearance: AppearanceController;

	readonly bannerContainer = new Container();
	readonly chatContainer = new TranscriptContainer();
	readonly queueContainer = new Container();
	readonly approvalContainer = new Container();
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
	readonly #switcher: SessionSwitcher;
	readonly #queuePanel: QueuePanelComponent;
	readonly #host: CommandHost;

	readonly #version: string;
	readonly #onExit: ((code: number) => void) | undefined;
	readonly #cwd: string;

	#disposers: Array<() => void> = [];
	#started = false;
	#queueMounted = false;
	/** True while the queue panel, rather than the editor, owns the keyboard. */
	#queueFocused = false;
	/** Set by Alt+Enter; consumed by the very next submission and then forgotten. */
	#modeOverride: SubmissionMode | undefined;

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
			onCycleMode: () => this.cycleSubmissionMode(),
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

		this.#queuePanel = new QueuePanelComponent({
			onEdit: (item) => this.editQueued(item),
			onDelete: (item) => this.deleteQueued(item),
			onBlur: () => this.blurQueue(),
			requestRender: () => this.tui.requestRender(),
		});
		this.approvals = new ApprovalController({
			store: this.store,
			methods: this.methods,
			events: this.events,
			tui: this.tui,
			container: this.approvalContainer,
			notice: (text, level) => this.events.notice(text, level),
			focusEditor: () => this.#restoreFocus(),
			refreshStatus: () => this.#renderStatus(),
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
		this.sessions = new SessionController({
			store: this.store,
			methods: this.methods,
			events: this.events,
			tui: this.tui,
			editor: this.#editor,
			sendPrompt: (text) => this.sendPrompt(text),
			refreshStatus: () => this.#renderStatus(),
			confirm: (spec) => this.#confirm(spec),
		});
		this.#switcher = new SessionSwitcher({
			store: this.store,
			methods: this.methods,
			present: (overlay) => this.selectors.open(overlay),
			repaint: () => this.selectors.repaint(),
			switchSession: (key) => this.sessions.switch(key),
			createSession: async (key, prompt) => {
				await this.sessions.create(key, prompt);
			},
			closeSession: (key) => this.sessions.requestClose(key),
			notice: (text, level) => this.events.notice(text, level),
		});
		this.appearance = new AppearanceController({
			terminal: this.tui.terminal,
			preference: options.themePreference,
			onChange: () => this.#themeChanged(),
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
			sink: { deliver: (text, options) => this.sendPrompt(text, options) },
			tui: this.tui,
			cwd: this.#cwd,
		});
		this.input = new InputController({
			tui: this.tui,
			// A pending approval is modal: Ctrl+L must not clear the transcript out
			// from under a question the daemon is blocked on.
			hasOverlay: () => this.selectors.isOpen || this.approvals.panel.visible,
			openModelPicker: () => this.#modelPicker.open(),
			openSessionSwitcher: () => this.#switcher.open(),
			openExternalEditor: () => this.openExternalEditor(),
			clearTranscript: () => this.#host.clearTranscript(),
			focusQueue: () => this.focusQueue(),
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
		this.approvals.attach();
		this.#disposers.push(
			this.client.events.on("state", () => this.#renderConnection()),
			this.client.events.on("queued", () => {
				this.#renderConnection();
				this.syncQueuePanel();
			}),
			this.client.events.on("queue-flushed", () => {
				this.#renderConnection();
				this.syncQueuePanel();
			}),
			// A finished run is the moment the branch and the token budget can
			// both have moved, and the only one worth spending a request on. It is
			// also the moment the session's backlog is allowed to move.
			this.client.events.on("agent", (event: AgentEvent) => {
				if (event?.type !== "completed") return;
				void this.#statusBar.refreshBranch();
				void this.refreshUsage();
				void this.drainQueue((event as AgentCompletedEvent).sessionKey ?? this.store.focusedKey);
			}),
			// A re-handshake means the client's picture of the daemon is stale: which
			// sessions are live, what landed while the socket was down, and which
			// approvals are still waiting all have to be re-read.
			this.client.events.on("resync-needed", () => void this.sessions.resync()),
			this.store.events.on("mode-changed", () => this.#renderStatus()),
			this.store.events.on("session-changed", () => this.syncQueuePanel()),
			this.store.queue.events.on("changed", ({ sessionKey }) => {
				if (sessionKey === this.store.focusedKey) this.syncQueuePanel();
				this.#renderStatus();
			}),
			() => this.#statusBar.dispose(),
			() => this.selectors.dispose(),
			() => this.approvals.dispose(),
			() => this.input.dispose(),
		);
		this.tui.start();
		// After tui.start(), so the terminal is listening when pi-tui's OSC 11
		// query comes back with the background color.
		this.appearance.start();
		this.#statusBar.start();
		this.#renderStatus();
		try {
			await this.client.connect();
			// Only now are the daemon's methods known, so this is the first moment the
			// status bar can name the model instead of guessing at "no model".
			void this.sessions.hydrateRouting(this.store.focused);
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
		this.#buildBanner();
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
		this.tui.addChild(this.queueContainer);
		this.tui.addChild(this.approvalContainer);
		this.tui.addChild(this.statusContainer);
		this.tui.addChild(this.statusLineContainer);
		this.tui.addChild(this.editorContainer);
		this.tui.setFocus(this.#editor);
		this.#renderConnection();
	}

	/** The banner text, rebuilt whenever the palette changes under it. */
	#buildBanner(): void {
		const theme = getTheme();
		this.#banner.setText(
			`${theme.fg("bannerTitle", "lemon")} ${theme.fg("bannerSubtitle", `tui ${this.#version}`)}  ${theme.fg(
				"dim",
				"/help · Ctrl+X sessions · Ctrl+O model · Ctrl+G editor · Ctrl+C abort/quit",
			)}`,
		);
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
		const context = contextGauge(session, this.store);
		return {
			sessionKey: session.key,
			model: session.model,
			contextTokens: context.tokens,
			contextWindow: context.window,
			contextSource: context.source,
			sessionCount: this.store.sessions.size,
			busy: session.busy,
			busySessions: this.store.busySessions(),
			unread: this.store.totalUnread(),
			approvals: this.store.pendingApprovals,
			connection: this.client.state,
			// What the *next* prompt will do, which is what the user is about to
			// decide — not the standing default it may be overriding.
			mode: this.effectiveMode,
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
			// The reply is the daemon agreeing to stop, which is the moment the
			// partial answer becomes final: seal it with the interrupted marker
			// rather than waiting for a `completed` that may never describe it as
			// anything but a normal end.
			.then(() => this.events.markInterrupted(runId, session))
			.catch((error) => this.events.notice(`abort failed: ${describeError(error)}`, "error"));
		return true;
	}

	// -- the queue ------------------------------------------------------------

	/** Focus the queue panel. False when there is nothing queued to focus. */
	focusQueue(): boolean {
		this.syncQueuePanel();
		if (!this.#queuePanel.visible) return false;
		this.#queueFocused = true;
		this.#queuePanel.focused = true;
		this.tui.setFocus(this.#queuePanel);
		this.tui.requestRender();
		return true;
	}

	/** Hand the keyboard back to the editor, leaving the queue on screen. */
	blurQueue(): void {
		this.#queueFocused = false;
		this.#queuePanel.focused = false;
		this.#focusEditor();
	}

	/** Enter in the panel: the item goes back to being a draft. */
	editQueued(item: QueueItem): void {
		if (item.state !== "queued-local") {
			this.events.notice("that one is already on its way to the daemon", "warning");
			return;
		}
		this.store.queue.remove(this.store.focusedKey, item.id);
		this.#editor.setText(item.text);
		this.blurQueue();
	}

	deleteQueued(item: QueueItem): void {
		if (item.state !== "queued-local") {
			this.events.notice("that one is already on its way to the daemon", "warning");
			return;
		}
		this.store.queue.remove(this.store.focusedKey, item.id);
	}

	/**
	 * Mirror the store into the panel, mounting or unmounting it as the backlog
	 * appears and empties. Requests the protocol client parked while offline are
	 * shown alongside ours: from the user's seat both are "typed but not answered",
	 * and hiding half of that would make the client look like it lost a prompt.
	 */
	syncQueuePanel(): void {
		const key = this.store.focusedKey;
		const local = this.store.queue.items(key);
		const parked = this.client.queued
			.filter(
				(entry) =>
					entry.method === METHOD.chatSend && pickString(entry.params, "sessionKey") === key,
			)
			.map(
				(entry): QueueItem => ({
					id: `offline:${entry.id}`,
					text: pickString(entry.params, "prompt") ?? "",
					state: "waiting-connection",
					at: 0,
				}),
			);
		const items = parked.length > 0 ? [...local, ...parked] : local;
		this.#queuePanel.update(items);
		if (items.length === 0) this.#unmountQueue();
		else this.#mountQueue();
		this.tui.requestRender();
	}

	/**
	 * Send the head of a session's backlog now that its run is over. One item per
	 * completion: the next one waits for the run this one starts, which is what
	 * makes the queue a queue rather than a burst.
	 */
	async drainQueue(sessionKey: string): Promise<void> {
		const session = this.store.sessions.get(sessionKey);
		if (!session || session.busy) return;
		const item = this.store.queue.shift(sessionKey);
		if (!item) return;
		await this.#send(item.text, session);
	}

	#mountQueue(): void {
		if (this.#queueMounted) return;
		this.#queueMounted = true;
		this.queueContainer.addChild(this.#queuePanel);
	}

	#unmountQueue(): void {
		if (!this.#queueMounted) return;
		this.#queueMounted = false;
		this.queueContainer.clear();
		const hadFocus = this.#queueFocused;
		this.#queueFocused = false;
		this.#queuePanel.focused = false;
		if (hadFocus) this.#focusEditor();
	}

	#focusEditor(): void {
		this.tui.setFocus(this.#editor);
		this.tui.requestRender();
	}

	/** Where focus belongs once a modal panel goes away. */
	#restoreFocus(): void {
		if (this.#queueFocused && this.#queuePanel.visible) {
			this.tui.setFocus(this.#queuePanel);
			this.tui.requestRender();
			return;
		}
		this.#focusEditor();
	}

	/**
	 * Alt+Enter: pick a different mode for the next submission without changing
	 * the default. One-shot because that is what the key is for — the standing
	 * choice is `/mode`, and a chord that silently rewrote it would make the
	 * status line's promise wrong for every prompt after this one.
	 */
	cycleSubmissionMode(): SubmissionMode {
		const current = this.#modeOverride ?? this.store.submissionMode;
		const index = SUBMISSION_MODES.indexOf(current);
		const next = SUBMISSION_MODES[(index + 1) % SUBMISSION_MODES.length]!;
		this.#modeOverride = next;
		this.events.notice(`next submission: ${next} (alt+enter cycles · /mode sets the default)`);
		this.#renderStatus();
		return next;
	}

	/** The mode the next submission will use, override included. */
	get effectiveMode(): SubmissionMode {
		return this.#modeOverride ?? this.store.submissionMode;
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
	 * The prompt sink, and the whole submission state machine.
	 *
	 *   idle                     -> `chat.send` (the daemon's default, collect)
	 *   busy + queue             -> held in the {@link QueueStore}, never sent
	 *   busy + steer             -> `chat.send queueMode: steer`
	 *   busy + interrupt         -> `chat.send queueMode: interrupt`, and the
	 *                               partial answer is sealed as interrupted
	 *
	 * Both degradations are visible rather than silent. Steering a run that just
	 * ended is a lost race, not a mistake, so the prompt still goes out as a new
	 * turn and says so; a daemon that refuses `steer` or `interrupt` outright
	 * leaves the prompt in the queue, where the user can still get at it, instead
	 * of dropping it on the floor.
	 */
	async sendPrompt(text: string, options: DeliverOptions = {}): Promise<void> {
		const prompt = text.trim();
		if (prompt.length === 0) return;
		const session = this.store.focused;
		const mode = options.mode ?? this.#takeModeOverride();
		this.#editor.disarm();

		if (!session.busy) {
			if (mode !== "queue" && justFinished(session)) {
				this.events.notice(`the run finished first — sending as a new turn`, "warning", session);
			}
			await this.#send(prompt, session);
			return;
		}
		if (mode === "queue") {
			this.store.queue.push(session.key, prompt);
			this.events.notice(
				`queued (${this.store.queue.length(session.key)}) — ctrl+q to edit`,
				"info",
				session,
			);
			return;
		}
		await this.#sendWhileBusy(prompt, session, mode);
	}

	/** A plain send: echo, dispatch, remember the run. */
	async #send(prompt: string, session: SessionStore, queueMode?: QueueMode): Promise<void> {
		this.events.addUserBlock(prompt, session);
		try {
			const result = await this.methods.chatSend({
				sessionKey: session.key,
				prompt,
				...(queueMode ? { queueMode } : {}),
			});
			if (result?.runId) this.events.noteRunStarted(result.runId, session);
		} catch (error) {
			this.events.notice(`send failed: ${describeError(error)}`, "error", session);
		}
	}

	/**
	 * Steer or interrupt a run in flight.
	 *
	 * The send is awaited *before* anything is drawn: an interrupt that the
	 * daemon refuses must not leave a run marked as stopped when it is still
	 * going, and the echo of the interrupting prompt has to land below the block
	 * it interrupted, not above it.
	 */
	async #sendWhileBusy(
		prompt: string,
		session: SessionStore,
		mode: Exclude<SubmissionMode, "queue">,
	): Promise<void> {
		const runId = session.activeRunId;
		try {
			const result = await this.methods.chatSend({
				sessionKey: session.key,
				prompt,
				queueMode: mode,
			});
			if (mode === "interrupt" && runId) this.events.markInterrupted(runId, session);
			this.events.addUserBlock(prompt, session);
			if (result?.runId) this.events.noteRunStarted(result.runId, session);
		} catch (error) {
			this.store.queue.push(session.key, prompt);
			this.events.notice(
				`${mode} refused (${describeError(error)}) — queued instead, ctrl+q to edit`,
				"warning",
				session,
			);
		}
	}

	/** Read and clear the one-shot Alt+Enter override. */
	#takeModeOverride(): SubmissionMode {
		const override = this.#modeOverride;
		this.#modeOverride = undefined;
		if (override) this.#renderStatus();
		return override ?? this.store.submissionMode;
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
			openSessionSwitcher: () => void this.#switcher.open(),
			switchSession: (sessionKey: string) => this.sessions.switch(sessionKey),
			createSession: async (sessionKey?: string, prompt?: string) => {
				await this.sessions.create(sessionKey, prompt);
			},
			closeSession: (sessionKey: string) => this.sessions.requestClose(sessionKey),
			resetSession: (sessionKey: string) => this.sessions.resetLocal(sessionKey),
			focusQueue: () => this.focusQueue(),
			queuedPrompts: () => this.store.queue.items(this.store.focusedKey).map((item) => item.text),
			resolveApproval: (approvalId: string, decision: string) =>
				this.approvals.resolve(approvalId, decision),
			markInterrupted: (runId: string) => this.events.markInterrupted(runId),
			keyHelp: () => [
				...this.input.describe(),
				"alt+enter — use a different submission mode for the next prompt only",
			],
			frameLog: () => this.client.recentFrames(),
			replayHistory: (messages: ChatHistoryMessage[]) => this.#replayHistory(messages),
			openModelPicker: () => this.#modelPicker.open(),
			themeChanged: () => this.#themeChanged(),
			setThemePreference: (preference: ThemePreference) =>
				this.appearance.setPreference(preference),
			themeStatus: () => ({
				preference: this.appearance.preference,
				appearance: this.appearance.appearance,
				source:
					this.appearance.preference === "auto"
						? this.appearance.reported
							? "the terminal"
							: "the default"
						: "your setting",
			}),
		};
	}

	/**
	 * Repaint everything in the new palette. The theme object is mutated rather
	 * than replaced, so the style functions components captured keep working —
	 * but every cached *row* in the tree was rendered with the old colors, hence
	 * the tree-wide invalidate and the forced redraw.
	 */
	#themeChanged(): void {
		this.#buildBanner();
		this.tui.invalidate();
		this.tui.requestRender(true);
	}

	/** A two-option overlay for a decision that cannot be undone. */
	#confirm(spec: ConfirmSpec): void {
		const overlay = new PickerOverlay({
			title: spec.title,
			items: [
				{ value: "confirm", label: spec.confirmLabel },
				{ value: "cancel", label: "cancel" },
			],
			footer: "enter chooses · esc cancels",
			onSelect: (item) => {
				this.selectors.close();
				if (item.value === "confirm") void spec.onConfirm();
				else spec.onCancel?.();
			},
			onCancel: () => {
				this.selectors.close();
				spec.onCancel?.();
			},
		});
		this.selectors.open(overlay);
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
		synthesizeHistory(this.store.focused, messages);
		this.events.rebuildFocused();
		this.tui.requestRender(true, { clearScrollback: true });
	}
}

/**
 * What the gauge shows, and how honestly it can be labelled.
 *
 * A session that has completed a run knows its own context size from the run's
 * usage, which is a real denominator-bearing measurement and gets a bar. Before
 * that, all the client has is `usage.status` — every session's tokens for the
 * whole day — so the segment falls back to `use 12k` rather than pretending a
 * day's total is a conversation's size.
 */
export function contextGauge(
	session: SessionStore,
	store: AppStore,
): { tokens: number | undefined; window: number | undefined; source: ContextSource } {
	const window = session.contextWindow ?? contextWindowFor(store, session.model);
	const own = session.contextTokens;
	if (own !== undefined) return { tokens: own, window, source: "context" };
	return { tokens: contextTokensFrom(store.usage), window, source: "aggregate" };
}

/**
 * Today's token totals from `usage.status`, for the fallback segment.
 *
 * An explicit context field is preferred wherever a daemon provides one; the
 * totals are the documented fallback.
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
	return contextWindowFromCache(store.models, model);
}

function describeError(error: unknown): string {
	if (error instanceof Error) return error.message;
	return String(error);
}

/** How long after a run ends a `steer` still counts as having lost a race. */
export const STEER_GRACE_MS = 2000;

/**
 * True when the session's run ended moments ago. A `steer` submitted in that
 * window was aimed at a run that was still going when the user pressed Enter,
 * so it earns an explanation; one typed into a long-idle session is just a
 * prompt and gets none.
 */
export function justFinished(session: SessionStore, nowMs: number = Date.now()): boolean {
	if (session.lastRunEndedAtMs <= 0) return false;
	return nowMs - session.lastRunEndedAtMs < STEER_GRACE_MS;
}
