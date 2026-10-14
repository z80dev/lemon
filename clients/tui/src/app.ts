/**
 * AppShell — the client's root wiring.
 *
 * Flat container order (later phases slot components into the same seams):
 *
 *   banner        welcome + connection state
 *   chat          TranscriptContainer: ordered semantic history and live blocks
 *   queue         the editable backlog, when there is one
 *   approval      the decision panel, when a tool is waiting
 *   status        spare slot above the status line
 *   statusLine    one line: session, activity, approvals
 *   editor        the prompt
 *
 * RowFrameProvider splits main (banner/transcript) from the mutable dock
 * (queue/approval/status/editor). Dock rows never enter native scrollback.
 *
 * Wiring rules this file keeps to, because later phases depend on them:
 *   - controllers own the stores and the UI; components stay dumb
 *   - {@link EventController} is the only writer of store + transcript
 *   - the accumulated delta buffer is the source of truth for a run's final
 *     text (`agent completed.answer` is server-truncated to 500 bytes)
 *   - nothing here calls `process.exit`; `onExit` hands that to main.ts
 */

import {
	setTranscriptActionHandler,
	type TranscriptAction,
} from "@oh-my-pi/pi-tui/chat/transcript-actions";
import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import { CLOSE_ACTION, pickerAction } from "@oh-my-pi/pi-tui/native/picker";
import { ProcessTerminal, type Terminal } from "@oh-my-pi/pi-tui/terminal";
import { Container, TUI } from "@oh-my-pi/pi-tui/tui";
import * as postmortem from "@oh-my-pi/pi-utils/postmortem";
import { indentBlock, pick, pickNumber, pickString } from "./commands/format.ts";
import { type CommandHost, type CommandRegistry, createCommandRegistry } from "./commands/index.ts";
import { contextWindowFromCache } from "./commands/model.ts";
import { parsePlanReceipt } from "./commands/plan.ts";
import { SUBMISSION_MODES } from "./commands/registry.ts";
import {
	ComposerDrafts,
	type ComposerSubmission,
	type SubmissionDisposition,
} from "./composer/drafts.ts";
import { editInExternalEditor } from "./external-editor.ts";
import { getGitModeline } from "./git-utils.ts";
import { ControlPlaneClient } from "./protocol/client.ts";
import { ControlPlaneError } from "./protocol/errors.ts";
import { ControlPlaneMethods, METHOD } from "./protocol/methods.ts";
import {
	type AgentCompletedEvent,
	type AgentEvent,
	type ChatHistoryMessage,
	type ImageContent,
	PROPOSE_PLAN_TOOL,
	type QueueMode,
} from "./protocol/types.ts";
import { newSessionKey } from "./session-key.ts";
import { AppStore, type SubmissionMode } from "./store/app-store.ts";
import type { QueueItem } from "./store/queue-store.ts";
import type { SessionStore } from "./store/session-store.ts";
import type { CompactionDetails, NoticeLevel } from "./store/transcript-model.ts";
import { type ForkLaunch, openForkSession } from "./terminal/fork.ts";
import { TerminalIntegration } from "./terminal/integration.ts";
import { isApprovedDecision } from "./ui/components/approval-panel.ts";
import { Banner } from "./ui/components/banner.ts";
import { ContextPanelComponent } from "./ui/components/context-panel.ts";
import { CustomEditor } from "./ui/components/custom-editor.ts";
import { ModelPicker } from "./ui/components/model-picker.ts";
import { confirmAction, PickerOverlay } from "./ui/components/pickers.ts";
import { QueuePanelComponent } from "./ui/components/queue-panel.ts";
import { SessionSwitcher } from "./ui/components/session-switcher.ts";
import {
	type ContextSource,
	type StatusAction,
	StatusBar,
	type StatusBarData,
} from "./ui/components/status-bar.ts";
import { TranscriptContainer } from "./ui/components/transcript-container.ts";
import { ClampedText } from "./ui/components/width-safe.ts";
import { WorkingIndicatorComponent } from "./ui/components/working-indicator.ts";
import { ApprovalController } from "./ui/controllers/approval-controller.ts";
import { CommandController, type DeliverOptions } from "./ui/controllers/command-controller.ts";
import { CommandPalette } from "./ui/controllers/command-palette.ts";
import { EventController } from "./ui/controllers/event-controller.ts";
import { InputController, LEMON_KEYBINDINGS } from "./ui/controllers/input-controller.ts";
import { OmpController } from "./ui/controllers/omp-controller.ts";
import { SelectorController } from "./ui/controllers/selector-controller.ts";
import {
	type ConfirmSpec,
	SessionController,
	synthesizeHistory,
} from "./ui/controllers/session-controller.ts";
import { TaskTreeController } from "./ui/controllers/task-tree-controller.ts";
import { ToolInspector } from "./ui/controllers/tool-inspector.ts";
import { RowFrameProvider } from "./ui/row-frame-provider.ts";
import { AppearanceController, type ThemePreference } from "./ui/theme/appearance.ts";
import { getTheme } from "./ui/theme/theme.ts";
import { getEditorTheme } from "./ui/theme/tui-adapters.ts";

export interface AppShellOptions {
	url: string;
	/** Shared control-plane operator credential. Never displayed or logged. */
	operatorToken?: string;
	/** Session to talk to. Defaults to a fresh canonical TUI channel-peer key. */
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

export class AppShell {
	readonly tui: TUI;
	readonly client: ControlPlaneClient;
	readonly methods: ControlPlaneMethods;
	readonly store: AppStore;
	readonly composerDrafts = new ComposerDrafts();
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

	readonly #banner: Banner;
	// Clamped: pi-tui keeps a Text's horizontal padding at every width, so a very
	// narrow terminal would otherwise get chrome rows wider than the frame.
	readonly #connectionLine = new ClampedText("", 1, 0);
	readonly #statusBar: StatusBar;
	readonly #editor: CustomEditor;
	readonly #modelPicker: ModelPicker;
	readonly #switcher: SessionSwitcher;
	readonly #queuePanel: QueuePanelComponent;
	readonly #host: CommandHost;
	readonly #palette: CommandPalette;
	readonly #taskTree: TaskTreeController;
	readonly #omp: OmpController;
	readonly #toolInspector: ToolInspector;
	/** Native dock working row; paints nothing in the row renderer. */
	readonly #working = new WorkingIndicatorComponent({
		activeRun: () => (this.store.focused.busy ? this.store.focused.activeRunId : undefined),
		onInterrupt: () => {
			this.#abortActiveRun();
		},
	});

	readonly #onExit: ((code: number) => void) | undefined;
	readonly #cwd: string;
	readonly #forkConnection: Pick<ForkLaunch, "url" | "operatorToken">;
	readonly #terminalIntegration: TerminalIntegration;

	#disposers: Array<() => void> = [];
	#unregisterTerminalCleanup: (() => void) | undefined;
	readonly #drainingSessions = new Set<string>();
	#started = false;
	#sessionReady = false;
	#initialSessionLoad: Promise<void> | undefined;
	#queueMounted = false;
	/** True while the queue panel, rather than the editor, owns the keyboard. */
	#queueFocused = false;
	/** Set by Alt+Enter; consumed by the very next submission and then forgotten. */
	#modeOverride: SubmissionMode | undefined;
	/**
	 * Ephemeral routing hints for profile chats opened in this process. The
	 * daemon remains authoritative: entries come from profile RPC responses,
	 * are never persisted, and `profile.chat` revalidates the id on every send.
	 */
	readonly #profileSessions = new Map<string, string>();

	constructor(options: AppShellOptions) {
		this.#banner = new Banner(options.version ?? "dev");
		this.#onExit = options.onExit;
		this.#cwd = options.cwd ?? process.cwd();
		this.#forkConnection = { url: options.url, operatorToken: options.operatorToken };
		this.client =
			options.client ?? new ControlPlaneClient({ url: options.url, token: options.operatorToken });
		this.methods = new ControlPlaneMethods(this.client);
		this.tui = options.tui ?? new TUI(options.terminal ?? new ProcessTerminal());
		this.store = new AppStore(options.sessionKey ?? newSessionKey());
		this.#terminalIntegration = new TerminalIntegration(
			this.tui.terminal,
			this.store,
			this.client,
			this.#cwd,
			undefined,
			() => {
				if (this.tui.nativeRendering) this.tui.renderNow();
			},
		);
		// Editor construction needs a theme: pi-tui ships no defaults.
		this.#editor = new CustomEditor({
			theme: getEditorTheme(),
			onSubmit: (text) => this.submit(text),
			canSubmit: () =>
				this.#sessionReady &&
				this.client.online &&
				!this.selectors.isOpen &&
				!this.approvals.panel.visible,
			composer: {
				drafts: this.composerDrafts,
				sessionKey: () => this.store.focusedKey,
				cwd: () => this.#cwd,
				submit: (submission) => this.#submitAttachments(submission),
			},
			onAbort: () => this.#abortActiveRun(),
			onQuit: (code) => this.requestExit(code),
			onExternalEdit: () => this.openExternalEditor(),
			onCycleMode: () => this.cycleSubmissionMode(),
			notice: (text, level) => this.events.notice(text, level),
			requestRender: () => this.tui.requestRender(),
			// The TSP composer's chips take their keys' paths, and like the keys
			// they defer to an open overlay.
			composerState: () => {
				const session = this.store.focused;
				return { running: session.busy, thinking: session.thinkingLevel, title: session.title };
			},
			onSelectModel: () => {
				if (!this.#hasOverlay()) void this.#modelPicker.open();
			},
			onSelectThinking: () => {
				if (!this.#hasOverlay()) void this.submit("/think");
			},
			controlKeys: {
				model: LEMON_KEYBINDINGS["lemon.picker.model"].defaultKeys,
				thinking: LEMON_KEYBINDINGS["lemon.picker.thinking"].defaultKeys,
			},
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
			onNativeAction: (action) => this.#statusAction(action),
		});
		// A TSP terminal draws no status strip: the composer carries its facts.
		this.#editor.composerFacts = this.#statusBar;
		this.selectors = new SelectorController({
			tui: this.tui,
			defaultFocus: () => this.#editor,
		});
		this.#toolInspector = new ToolInspector({
			store: this.store,
			rows: () => this.tui.terminal.rows,
			present: (component) => this.selectors.open(component),
			repaint: () => this.selectors.repaint(),
			notice: (text) => this.events.notice(text),
		});
		this.#taskTree = new TaskTreeController({
			requestRender: () => this.tui.requestRender(),
			onBlur: () => this.#focusEditor(),
		});
		this.#taskTree.setSession(this.store.focusedKey);
		this.#omp = new OmpController({
			store: this.store.omp,
			methods: this.methods,
			client: this.client,
			cwd: this.#cwd,
			requestRender: () => this.tui.requestRender(),
			onBlur: () => {
				this.#omp.panel.focused = false;
				this.#focusEditor();
			},
			notice: (text, level) => this.events.notice(text, level),
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
			cwd: this.#cwd,
			sendPrompt: (text) => this.sendPrompt(text),
			refreshStatus: () => this.#renderStatus(),
			confirm: (spec) => this.#confirm(spec),
			onSnapshot: (result, branchChanged, terminalAdvance) => {
				if (branchChanged) this.#taskTree.store.clear(result.sessionKey);
				this.#taskTree.reconcile(result.sessionKey, result.snapshot.children);
				// Events for recovered runs only request owner reconciliation. Advance
				// known-unsent work on its verified terminal transition, never a preview.
				if (terminalAdvance && this.client.online) void this.drainQueue(result.sessionKey);
			},
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
		this.#palette = new CommandPalette({
			context: () => ({
				store: this.store,
				session: this.store.focused,
				methods: this.methods,
				client: this.client,
				ui: this.#host,
				registry: this.commands,
				cwd: this.#cwd,
				name: "palette",
				rest: "",
			}),
			getDraft: () => this.#editor.getExpandedText(),
			setDraft: (text) => this.#host.setDraft(text),
			present: (overlay) => this.selectors.open(overlay),
			repaint: () => this.selectors.repaint(),
			notice: (text, level) => this.events.notice(text, level),
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
			openThinkingPicker: () => this.submit("/think"),
			openSessionSwitcher: () => this.#switcher.open(),
			openExternalEditor: () => this.openExternalEditor(),
			clearTranscript: () => this.#host.clearTranscript(),
			focusQueue: () => this.focusQueue(),
			toggleLatest: () => this.events.toggleLatestBlock(),
			cycleDetail: () => this.events.cycleAccordionOverride(),
			openCommandPalette: (mode) => this.#palette.open(undefined, mode),
			isComposerEmpty: () => this.#editor.getText().length === 0,
			toggleTaskTree: () => this.#toggleTaskTree(),
			toggleOmpPanel: () => this.#toggleOmpPanel(),
			toggleToolOutputs: () => {
				this.events.toggleToolOutputs();
			},
			openDiff: () => this.#toolInspector.open("diff"),
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
		this.#omp.attach();
		this.#disposers.push(
			this.tui.addInputListener((data) => this.#terminalIntegration.handleInput(data)),
			this.client.events.on("state", () => this.#renderConnection()),
			this.client.events.on("hello-ok", () => {
				// Every handshake, resumed or not: plan mode may have moved while away.
				void this.refreshPlanMode();
				if (this.#sessionReady || this.#initialSessionLoad) return;
				this.#initialSessionLoad = this.sessions
					.initialize()
					.then(() => {
						this.#sessionReady = true;
					})
					.catch((error: unknown) =>
						this.events.notice(`could not load session: ${describeError(error)}`, "error"),
					)
					.finally(() => {
						this.#initialSessionLoad = undefined;
						this.tui.requestRender();
					});
			}),
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
				const session = this.store.session(event.sessionKey ?? this.store.focusedKey);
				if (session.snapshotIdentity) {
					// Background recovered runs still own their local queue. Their
					// completion preview requests owner truth; it never drains directly.
					if (
						event.type === "completed" &&
						session !== this.store.focused &&
						this.store.queue.items(session.key)[0]?.state === "queued-local"
					)
						void this.sessions.resync(session.key);
					return;
				}
				this.#taskTree.ingest(event);
				this.#toolInspector.refresh();
				if (event?.type !== "completed") return;
				const completedKey = (event as AgentCompletedEvent).sessionKey ?? this.store.focusedKey;
				void this.#statusBar.refreshBranch();
				void this.refreshUsage();
				// The authoritative resync after an approved plan flipped the mode mid-run.
				if (completedKey === this.store.focusedKey) void this.refreshPlanMode(completedKey);
				void this.drainQueue(completedKey);
			}),
			// A re-handshake means the client's picture of the daemon is stale: which
			// sessions are live, what landed while the socket was down, and which
			// approvals are still waiting all have to be re-read.
			this.client.events.on("resync-needed", ({ sessionKey }) => {
				for (const session of this.store.sessions.values()) {
					if (sessionKey && session.key !== sessionKey) continue;
					if (
						session !== this.store.focused &&
						(!session.snapshotIdentity ||
							!session.busy ||
							this.store.queue.items(session.key)[0]?.state !== "queued-local")
					)
						continue;
					// Loss/reconnect also races an owner read when no data packet landed.
					session.recoveryEventVersion += 1;
					void this.sessions.resync(session.key);
				}
			}),
			this.store.events.on("mode-changed", () => this.#renderStatus()),
			this.store.events.on("session-changed", () => {
				this.syncQueuePanel();
				this.#palette.close();
				this.#toolInspector.close();
				this.#taskTree.setSession(this.store.focusedKey);
				void this.refreshPlanMode();
			}),
			// Approving a plan proposal turns plan mode off server-side; refining it
			// keeps plan mode on with a (possibly new) plan file.
			this.store.events.on("approval-resolved", ({ approval, decision }) => {
				const { event } = approval;
				if (event.tool !== PROPOSE_PLAN_TOOL) return;
				const sessionKey = event.sessionKey ?? this.store.focusedKey;
				const approved = isApprovedDecision(decision);
				if (approved) {
					this.store.session(sessionKey).setPlan("code");
					this.#renderStatus();
				}
				void this.refreshPlanMode(sessionKey, { afterApproval: approved });
			}),
			this.store.queue.events.on("changed", ({ sessionKey }) => {
				if (sessionKey === this.store.focusedKey) this.syncQueuePanel();
				this.#renderStatus();
			}),
			this.store.omp.events.on("changed", () => this.#renderStatus()),
			() => this.#statusBar.dispose(),
			() => this.selectors.dispose(),
			() => this.approvals.dispose(),
			() => this.input.dispose(),
			() => this.#palette.close(),
			() => this.#taskTree.dispose(),
			() => this.#omp.dispose(),
			() => this.#toolInspector.close(),
		);
		// Native transcript controls (Copy, Switch model) take their keys' paths.
		setTranscriptActionHandler((action) => this.#runTranscriptAction(action));
		this.#disposers.push(() => setTranscriptActionHandler(undefined));
		this.tui.start();
		this.#registerTerminalCleanup();
		this.#terminalIntegration.start();
		// After tui.start(), so the terminal is listening when pi-tui's OSC 11
		// query comes back with the background color.
		this.appearance.start();
		this.#statusBar.start();
		this.#renderStatus();
		try {
			await this.client.connect();
			// The explicit session may be a durable fork. Restore it before
			// advertising a sendable composer to terminal automation.
			await this.#initialSessionLoad;
		} catch (error) {
			// The socket keeps retrying in the background; just say so.
			this.events.notice(`connection failed: ${describeError(error)}`, "error");
		}
	}

	stop(): void {
		this.#unregisterTerminalCleanup?.();
		this.#unregisterTerminalCleanup = undefined;
		for (const dispose of this.#disposers.splice(0)) dispose();
		this.events.dispose();
		this.client.close();
		this.#terminalIntegration.stop();
		if (this.#started) this.tui.stop();
		this.#started = false;
	}

	#registerTerminalCleanup(): void {
		// Reverse-order signal cleanup must stop app writers before pi-tui's output pump,
		// including after an external editor has registered a new pi-tui cleanup.
		this.#unregisterTerminalCleanup?.();
		this.#unregisterTerminalCleanup = postmortem.register("lemon-tui", () => this.stop());
	}

	// -- ui -----------------------------------------------------------------

	#buildUi(): void {
		this.bannerContainer.addChild(this.#banner);
		this.bannerContainer.addChild(this.#connectionLine);
		this.statusLineContainer.addChild(this.#statusBar);
		this.statusContainer.addChild(this.#taskTree.panel);
		this.statusContainer.addChild(this.#omp.panel);
		this.statusContainer.addChild(this.#working);

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
		// A width replay replaces the old presentation instead of duplicating it.
		this.tui.setResizeScrollback("rebuild");
		this.tui.setFrameProvider(
			new RowFrameProvider(
				this.chatContainer,
				[this.bannerContainer],
				[
					this.queueContainer,
					this.approvalContainer,
					this.statusContainer,
					this.statusLineContainer,
					this.editorContainer,
				],
				this.tui,
			),
		);
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
		this.#terminalIntegration.update();
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
			runTokens: session.usage?.totalTokens ?? undefined,
			runCostUsd: session.usage?.costUsd ?? undefined,
			pendingPrompts: this.store.queue.length(session.key),
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
			planMode: session.planMode,
			ompBusy: this.store.omp.busyCount(),
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

	/**
	 * Re-read a session's plan mode for the status line. Never throws: a failed or
	 * malformed read keeps what was known, and a read overtaken by a newer local
	 * write (a `/plan` receipt, an approved proposal) is dropped.
	 *
	 * `afterApproval`: the daemon turns plan mode off a moment *after* the approval
	 * resolve returns, so a `plan` read here is that race rather than the truth;
	 * only a `code` confirmation is applied, and run completion resyncs.
	 */
	async refreshPlanMode(
		sessionKey: string = this.store.focusedKey,
		options: { afterApproval?: boolean } = {},
	): Promise<void> {
		if (!this.client.online || !this.methods.supports(METHOD.sessionsPlan)) return;
		const session = this.store.session(sessionKey);
		const writes = session.planWrites;
		try {
			const result = await this.methods.sessionsPlan({
				sessionKey,
				cwd: this.#cwd,
				action: "status",
			});
			const plan = parsePlanReceipt(result, sessionKey);
			if (session.planWrites !== writes) return;
			if (options.afterApproval && plan.mode !== "code") return;
			session.setPlan(plan.mode, plan.path);
			this.#renderStatus();
		} catch {
			// The indicator keeps its last known state; not worth a notice.
		}
	}

	// -- input --------------------------------------------------------------

	/** True while a picker/switcher or a pending approval owns the keyboard. */
	#hasOverlay(): boolean {
		return this.selectors.isOpen || this.approvals.panel.visible;
	}

	/** A click on a TSP composer fact: the same paths as the keys and commands for it. */
	#statusAction(action: StatusAction): void {
		if (this.#hasOverlay()) return;
		switch (action) {
			case "sessions":
				void this.#switcher.open();
				return;
			case "queue":
				if (!this.focusQueue()) this.events.notice("nothing is queued");
				return;
			case "mode":
				this.cycleSubmissionMode();
				return;
			case "approvals":
				void this.submit("/approvals");
				return;
			case "cost":
				void this.submit("/cost");
				return;
			case "context":
				void this.submit("/context");
				return;
			case "omp":
				this.#openOmpPanel();
				return;
		}
	}

	/** Native transcript controls: Copy goes to the clipboard over OSC 52, Switch model opens the picker. */
	#runTranscriptAction(action: TranscriptAction): void {
		if (action.act === "copy") {
			this.tui.terminal.write(`\x1b]52;c;${Buffer.from(action.text).toString("base64")}\x07`);
		} else if (action.act === "switch-model") {
			this.#modelPicker.open();
		}
	}

	/** Ctrl+C's first job. Returns true when there was a run to stop. */
	#abortActiveRun(): boolean {
		const session = this.store.focused;
		const runId = session.activeRunId;
		if (!runId) return false;
		this.events.notice("cancellation requested");
		void this.methods
			.chatAbort({ runId, sessionKey: session.key })
			.then((result) => {
				if (result.aborted) this.events.markInterrupted(runId, session);
			})
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

	#toggleTaskTree(): void {
		this.#taskTree.toggle();
		this.#taskTree.panel.focused = this.#taskTree.panel.visible;
		if (this.#taskTree.panel.visible) this.tui.setFocus(this.#taskTree.panel);
		else this.#focusEditor();
		this.tui.requestRender();
	}

	/** Alt+M: show or hide the omp panel, taking the keyboard while it is open. */
	#toggleOmpPanel(): void {
		if (this.#omp.panel.visible) {
			this.#omp.setVisible(false);
			this.#omp.panel.focused = false;
			this.#focusEditor();
			return;
		}
		this.#openOmpPanel();
	}

	/** `/omp`, the composer's omp fact: open (or refocus) the panel. */
	#openOmpPanel(): void {
		this.#taskTree.panel.focused = false;
		this.#omp.setVisible(true);
		this.#omp.panel.focused = true;
		this.tui.setFocus(this.#omp.panel);
		this.tui.requestRender();
	}

	/** Enter in the panel: the item goes back to being a draft. */
	editQueued(item: QueueItem): void {
		if (item.state === "waiting-connection") {
			this.events.notice("that one is already on its way to the daemon", "warning");
			return;
		}
		try {
			this.composerDrafts.add(this.store.focusedKey, item.attachments ?? []);
		} catch (error) {
			this.events.notice(`cannot restore queued images: ${describeError(error)}`, "error");
			return;
		}
		this.store.queue.remove(this.store.focusedKey, item.id);
		this.#editor.setText(item.text);
		this.blurQueue();
	}

	deleteQueued(item: QueueItem): void {
		if (item.state === "waiting-connection") {
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
		if (!session || session.busy || this.#drainingSessions.has(sessionKey)) return;
		if (this.store.queue.items(sessionKey)[0]?.state !== "queued-local") return;
		const item = this.store.queue.shift(sessionKey);
		if (!item) return;
		this.#drainingSessions.add(sessionKey);
		try {
			if (item.attachments?.length) {
				const disposition = await this.#submitAttachments(
					{
						sessionKey,
						text: item.text,
						attachments: item.attachments,
						images: item.attachments.map((image) => image.content),
					},
					false,
				);
				if (disposition === "rejected") {
					this.store.queue.restoreForReview(sessionKey, item);
					this.events.notice(
						"queued image send was not acknowledged; ctrl+q to review before retrying",
						"warning",
						session,
					);
				}
			} else {
				await this.#send(item.text, session);
			}
		} finally {
			this.#drainingSessions.delete(sessionKey);
		}
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
			const edited = await editInExternalEditor(draft, {
				tui: {
					stop: () => {
						this.#terminalIntegration.suspend();
						this.tui.stop();
					},
					start: () => {
						this.tui.start();
						this.#registerTerminalCleanup();
						this.#terminalIntegration.resume();
					},
				},
			});
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

	async #submitAttachments(
		submission: ComposerSubmission,
		allowQueue = true,
	): Promise<SubmissionDisposition> {
		const session = this.store.sessions.get(submission.sessionKey);
		if (!session) return "rejected";
		if (!submission.images.length) {
			if (session !== this.store.focused) return "rejected";
			await this.submit(submission.text);
			return "accepted";
		}
		if (/^[!/]/.test(submission.text.trim())) {
			this.events.notice(
				"image attachments belong to model prompts, not slash commands or shell escapes",
				"warning",
				session,
			);
			return "rejected";
		}
		const mode = allowQueue ? this.#takeModeOverride() : "queue";
		if (session.busy && mode === "queue") {
			if (!allowQueue) return "rejected";
			this.store.queue.push(session.key, submission.text, "queued-local", submission.attachments);
			this.events.notice(
				`queued with ${submission.images.length} image(s) — ctrl+q to edit`,
				"info",
				session,
			);
			return "queued";
		}
		// Never transfer images to an unacknowledged offline RPC: the editable
		// draft remains their owner until a concrete run or local queue accepts it.
		if (!this.client.online) {
			this.events.notice(
				"offline — image draft kept; reconnect before sending",
				"warning",
				session,
			);
			return "rejected";
		}
		const priorRun = session.activeRunId;
		const queueMode = session.busy && mode !== "queue" ? mode : undefined;
		try {
			const result = await this.#dispatchPrompt(
				session.key,
				submission.text,
				queueMode,
				submission.images,
			);
			if (typeof result?.runId !== "string" || !result.runId.trim()) {
				throw new Error("unverified send receipt; inspect the session before retrying");
			}
			if (queueMode === "interrupt" && priorRun) this.events.markInterrupted(priorRun, session);
			this.events.addUserBlock(
				[
					submission.text,
					...submission.attachments.map(
						(image) => `[image: ${image.name.replace(/\p{Cc}/gu, "")}]`,
					),
				]
					.filter(Boolean)
					.join("\n"),
				session,
				{
					images: submission.attachments.map((image) => image.content),
					...(queueMode ? { delivery: queueMode } : {}),
				},
			);
			this.events.noteRunStarted(result.runId, session);
			return "accepted";
		} catch (error) {
			this.events.notice(
				`image send not acknowledged: ${describeError(error)} — draft retained; inspect before retrying`,
				"error",
				session,
			);
			return "rejected";
		}
	}

	/**
	 * The prompt sink, and the whole submission state machine.
	 *
	 *   idle                     -> `chat.send`, or `profile.chat` for a canonical profile session
	 *   busy + queue             -> held in the {@link QueueStore}, never sent
	 *   busy + steer             -> authoritative route with `queueMode: steer`
	 *   busy + redirect          -> authoritative route with `queueMode: redirect`
	 *   busy + interrupt         -> authoritative route with `queueMode: interrupt`, and the
	 *                               partial answer is sealed as interrupted
	 *
	 * Both degradations are visible rather than silent. Steering a run that just
	 * ended is a lost race, not a mistake, so the prompt still goes out as a new
	 * turn and says so; a daemon that refuses `steer`, `redirect`, or `interrupt` outright
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

	/** A plain send: echo, dispatch through the session's authoritative route, remember the run. */
	async #send(prompt: string, session: SessionStore, queueMode?: QueueMode): Promise<void> {
		this.events.addUserBlock(prompt, session);
		try {
			const result = await this.#dispatchPrompt(session.key, prompt, queueMode);
			if (result?.runId) this.events.noteRunStarted(result.runId, session);
		} catch (error) {
			this.events.notice(`send failed: ${describeError(error)}`, "error", session);
		}
	}

	/**
	 * Steer, redirect, or interrupt a run in flight.
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
			const result = await this.#dispatchPrompt(session.key, prompt, mode);
			if (mode === "interrupt" && runId) this.events.markInterrupted(runId, session);
			this.events.addUserBlock(prompt, session, { delivery: mode });
			if (result?.runId) this.events.noteRunStarted(result.runId, session);
		} catch (error) {
			// Only an explicit refusal is known-unsent. Disconnects, timeouts and
			// uncertain submission receipts may already have changed the daemon.
			const refused =
				error instanceof ControlPlaneError &&
				pick(error.details, "retrySafe") !== false &&
				[
					"UNSUPPORTED",
					"NOT_IMPLEMENTED",
					"METHOD_NOT_FOUND",
					"INVALID_PARAMS",
					"FORBIDDEN",
					"UNAUTHORIZED",
					"PERMISSION_DENIED",
					"NOT_FOUND",
					"CONFLICT",
					"BUSY",
					"RATE_LIMITED",
				].includes(error.code);
			this.store.queue.push(session.key, prompt, refused ? "queued-local" : "needs-review");
			this.events.notice(
				refused
					? `${mode} refused (${describeError(error)}) — queued instead, ctrl+q to edit`
					: `${mode} outcome unknown (${describeError(error)}) — ctrl+q to review before retrying`,
				"warning",
				session,
			);
		}
	}

	/**
	 * Resolve canonical `agent:<id>:main` sessions through the profile API.
	 *
	 * A remembered route can be queued while disconnected. An unremembered
	 * canonical key is probed with `profiles.get` while online. Only that initial
	 * probe may prove the key belongs to a legacy non-profile session and fall
	 * back to `chat.send`. Once a profile route is confirmed, `profile.chat`
	 * failures never bypass the profile boundary (including deletion races).
	 */
	async #dispatchPrompt(
		sessionKey: string,
		prompt: string,
		queueMode?: QueueMode,
		images?: readonly ImageContent[],
	) {
		const media = images?.length ? { images } : undefined;
		const requestOptions = media ? { queueIfOffline: false } : undefined;
		const remembered = this.#profileSessions.get(sessionKey);
		if (remembered) {
			return await this.methods.profileChat(
				{
					id: remembered,
					prompt,
					...media,
					...(queueMode ? { queueMode } : {}),
				},
				requestOptions,
			);
		}

		const candidate = canonicalProfileId(sessionKey);
		if (
			!candidate ||
			!this.methods.supports(METHOD.profilesGet) ||
			!this.methods.supports(METHOD.profileChat)
		) {
			return await this.methods.chatSend(
				{
					sessionKey,
					cwd: this.#cwd,
					prompt,
					...media,
					...(queueMode ? { queueMode } : {}),
				},
				requestOptions,
			);
		}

		if (this.client.online) {
			try {
				const result = await this.methods.profilesGet({ id: candidate });
				if (!result.profile || result.profile.canonicalSessionKey !== sessionKey) {
					throw new Error(`profile ${candidate} returned a non-canonical session`);
				}
			} catch (error) {
				if (
					!ControlPlaneError.is(error, "NOT_FOUND") &&
					!ControlPlaneError.is(error, "METHOD_NOT_FOUND")
				) {
					throw error;
				}
				return await this.methods.chatSend(
					{
						sessionKey,
						prompt,
						cwd: this.#cwd,
						...media,
						...(queueMode ? { queueMode } : {}),
					},
					requestOptions,
				);
			}
		}

		const result = await this.methods.profileChat(
			{
				id: candidate,
				prompt,
				...media,
				...(queueMode ? { queueMode } : {}),
			},
			requestOptions,
		);
		if (result.sessionKey !== sessionKey) {
			throw new Error(`profile ${candidate} routed to an unexpected session`);
		}
		this.#profileSessions.set(sessionKey, candidate);
		return result;
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
			notice: (text: string, level?: NoticeLevel, compaction?: CompactionDetails) =>
				this.events.notice(text, level, undefined, compaction),
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
					detail: () => spec.detail,
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
			openMultiPicker: (spec) => {
				const selected = new Set(spec.selectedValues ?? []);
				const disabled = new Set(spec.disabledValues ?? []);
				const sourceItems = spec.items;
				const decoratedItems = () =>
					sourceItems.map((item) => ({
						...item,
						label: disabled.has(item.value)
							? `[installed] ${item.label}`
							: `${selected.has(item.value) ? "[x]" : "[ ]"} ${item.label}`,
					}));

				let overlay: PickerOverlay;
				const toggle = () => {
					const current = overlay.selected;
					if (!current || disabled.has(current.value)) return;
					if (selected.has(current.value)) selected.delete(current.value);
					else selected.add(current.value);
					const index = overlay.items.findIndex((item) => item.value === current.value);
					overlay.setItems(decoratedItems(), overlay.filter);
					overlay.setSelectedIndex(Math.max(0, index));
				};
				overlay = new PickerOverlay({
					title: spec.title,
					items: decoratedItems(),
					footer: spec.footer ?? "space toggles · enter imports · esc cancels",
					detail: () => `${selected.size} selected`,
					onKey: (data) => {
						if (!matchesKey(data, "space")) return false;
						toggle();
						return true;
					},
					sheet: {
						actions: () => [
							confirmAction("Confirm"),
							pickerAction("toggle", "Toggle", "space"),
							CLOSE_ACTION,
						],
						onAction: (act) => {
							if (act === "toggle") toggle();
						},
					},
					onSelect: () => {
						this.selectors.close();
						void spec.onConfirm(sourceItems.filter((item) => selected.has(item.value)));
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
			openFork: (sessionKey: string) =>
				openForkSession({ ...this.#forkConnection, sessionKey, cwd: this.#cwd }, (key) =>
					this.sessions.switch(key),
				),
			openProfile: async (profileId: string, sessionKey: string) => {
				this.#profileSessions.set(sessionKey, profileId);
				await this.sessions.switch(sessionKey);
			},
			forgetProfile: (profileId: string, sessionKey: string) => {
				if (this.#profileSessions.get(sessionKey) === profileId) {
					this.#profileSessions.delete(sessionKey);
				}
			},
			createSession: async (sessionKey?: string, prompt?: string) => {
				await this.sessions.create(sessionKey, prompt);
			},
			closeSession: (sessionKey: string) => this.sessions.requestClose(sessionKey),
			forgetDeletedSession: (sessionKey: string) => {
				this.composerDrafts.clear(sessionKey);
				this.#taskTree.store.clear(sessionKey);
				this.sessions.forgetDeleted(sessionKey);
			},
			resetSession: (sessionKey: string) => {
				this.#taskTree.store.clear(sessionKey);
				this.sessions.resetLocal(sessionKey);
			},
			reloadSession: (sessionKey: string) => this.sessions.reload(sessionKey),
			focusQueue: () => this.focusQueue(),
			deliverPrompt: (text: string, mode: SubmissionMode) => this.sendPrompt(text, { mode }),
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
			openCommandPalette: (query) => this.#palette.open(query),
			toggleTaskTree: () => this.#toggleTaskTree(),
			openOmpPanel: () => this.#openOmpPanel(),
			openToolOutput: (mode) => this.#toolInspector.open(mode),
			openContextPanel: (usage) => {
				let close = () => {};
				close = this.selectors.open(
					new ContextPanelComponent(usage, {
						rows: () => this.tui.terminal.rows,
						close: () => close(),
						repaint: () => this.selectors.repaint(),
					}),
				);
			},
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
		session.reasoningByActionId.clear();
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
 * usage, and `sessions.context` (via `/context` or the seed on focus) is the
 * daemon's own measurement; both are denominator-bearing and get a bar. Before
 * either, all the client has is `usage.status` — every session's tokens for the
 * whole day — so the segment falls back to `use 12k` rather than pretending a
 * day's total is a conversation's size.
 */
export function contextGauge(
	session: SessionStore,
	store: AppStore,
): { tokens: number | undefined; window: number | undefined; source: ContextSource } {
	const window =
		session.contextMeasurement?.window ??
		session.contextWindow ??
		contextWindowFor(store, session.model);
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

/** Extract only the stable profile main-session shape; no arbitrary keys qualify. */
export function canonicalProfileId(sessionKey: string): string | undefined {
	const match = sessionKey.match(/^agent:([a-z0-9][a-z0-9_-]{0,63}):main$/);
	return match?.[1];
}

/** How long after a run ends a live correction still counts as having lost a race. */
export const STEER_GRACE_MS = 2000;

/**
 * True when the session's run ended moments ago. A steer or redirect submitted in that
 * window was aimed at a run that was still going when the user pressed Enter,
 * so it earns an explanation; one typed into a long-idle session is just a
 * prompt and gets none.
 */
export function justFinished(session: SessionStore, nowMs: number = Date.now()): boolean {
	if (session.lastRunEndedAtMs <= 0) return false;
	return nowMs - session.lastRunEndedAtMs < STEER_GRACE_MS;
}
