/**
 * Lemon TUI - Terminal User Interface for the Lemon coding agent.
 */

import {
  TUI,
  ProcessTerminal,
  Text,
  Editor,
  Loader,
  Container,
  SelectList,
  matchesKey,
  CombinedAutocompleteProvider,
  type Component,
  type SelectItem,
} from '@mariozechner/pi-tui';
import { AgentConnection, AGENT_RESTART_EXIT_CODE, type AgentConnectionOptions } from './agent-connection.js';
import { StateStore, type AppState, type NormalizedAssistantMessage } from './state.js';
import type { ServerMessage, UIRequestMessage, SessionSummary, RunningSessionInfo } from './types.js';
import { slashCommands, MODELINE_PREFIXES, GIT_REFRESH_INTERVAL_MS } from './constants.js';
import { getGitModeline } from './git-utils.js';

import { ansi, getLemonArt } from './theme.js';
import { selectListTheme, editorTheme } from './component-themes.js';
import { MessageRenderer } from './message-renderer.js';
import { OverlayManager } from './overlay-manager.js';

// ============================================================================
// Main Application
// ============================================================================

export class LemonTUI {
  private tui: TUI;
  private connection: AgentConnection;
  private connectionOptions: AgentConnectionOptions;
  private store: StateStore;
  private agentRestartInFlight = false;

  private header: Text;
  private welcomeSection: Text;
  private welcomeVisible = true;
  private sessionsContainer: Container;
  private sessionsList: SelectList | null = null;
  private messagesContainer: Container;
  private widgetsContainer: Container;
  private toolPanel: Container;
  private toolExecutionBar: Text;
  private statusBar: Text;
  private modeline: Text;
  private inputEditor: Editor;
  private toolHint: Text;
  private loader: Loader | null = null;

  private overlayHandle: { hide: () => void } | null = null;
  private streamingComponent: Component | null = null;
  private currentOverlayRequestId: string | null = null;
  private toolPanelCollapsed = false;
  private lastSessions: SessionSummary[] = [];
  private processHandlersAttached = false;
  private gitRefreshTimer: ReturnType<typeof setInterval> | null = null;
  private gitRefreshInFlight = false;
  private gitCwd: string | null = null;
  private autocompleteBasePath: string | null = null;
  private pendingSessionAutoSwitch = false;
  private pendingRunningSessionsOverlay = false;
  private modelCatalog: Array<{
    id: string;
    models: Array<{ id: string; name?: string }>;
  }> | null = null;
  private pendingModelSelection: { cwd: string } | null = null;
  private toolExecutionTimer: ReturnType<typeof setInterval> | null = null;
  private messageRenderer: MessageRenderer;
  private overlayManager: OverlayManager;

  // Ctrl+C double-press handling
  private ctrlCHint: Text | null = null;
  private ctrlCTimer: ReturnType<typeof setTimeout> | null = null;
  private ctrlCFirstPress = false;
  private static readonly CTRL_C_TIMEOUT_MS = 2000;
  private escAbortHint: Text | null = null;
  private escAbortTimer: ReturnType<typeof setTimeout> | null = null;
  private escAbortFirstPress = false;
  private static readonly ESC_ABORT_TIMEOUT_MS = 2000;

  constructor(options: AgentConnectionOptions = {}) {
    this.tui = new TUI(new ProcessTerminal());
    this.connectionOptions = options;
    this.connection = new AgentConnection(options);
    this.store = new StateStore({ cwd: options.cwd });

    // Initialize components
    this.header = new Text('', 1, 0);
    this.welcomeSection = new Text('', 1, 1);
    this.sessionsContainer = new Container();
    this.widgetsContainer = new Container();
    this.messagesContainer = new Container();
    this.toolPanel = new Container();
    this.toolExecutionBar = new Text('', 1, 0);
    this.statusBar = new Text('', 1, 0);
    this.modeline = new Text('', 1, 0);
    this.inputEditor = new Editor(this.tui, editorTheme);
    this.toolHint = new Text('', 0, 0);
    this.messageRenderer = new MessageRenderer({
      isToolPanelCollapsed: () => this.toolPanelCollapsed,
    });
    this.overlayManager = new OverlayManager(
      this.tui,
      this.store,
      this.connection,
      {
        getOverlayHandle: () => this.overlayHandle,
        setOverlayHandle: (handle) => { this.overlayHandle = handle; },
        getCurrentOverlayRequestId: () => this.currentOverlayRequestId,
        setCurrentOverlayRequestId: (id) => { this.currentOverlayRequestId = id; },
        getInputEditor: () => this.inputEditor,
        getSessionsList: () => this.sessionsList,
        onOverlayHidden: () => {
          if (!this.store.getCurrentUIRequest()) {
            this.tui.setFocus(this.inputEditor);
          }
        },
      }
    );
    const initialBasePath = options.cwd || process.cwd();
    this.updateAutocompleteProvider(initialBasePath);

    // Apply debug setting from options (theme is set in main before constructing TUI)
    if (options.debug) {
      this.store.setDebug(true);
    }

    this.setupUI();
    this.setupEventHandlers();
  }

  private setupUI(): void {
    // Update header
    this.updateHeader();
    // Initialize welcome section
    this.updateWelcomeSection();

    // Add components to TUI
    // Tool panel and execution bar appear above messages so assistant response is always last
    this.tui.addChild(this.header);
    this.tui.addChild(this.welcomeSection);
    this.tui.addChild(this.sessionsContainer);
    this.tui.addChild(this.widgetsContainer);
    this.tui.addChild(this.toolPanel);
    this.tui.addChild(this.toolExecutionBar);
    this.tui.addChild(this.messagesContainer);
    this.tui.addChild(this.statusBar);
    this.tui.addChild(this.inputEditor);
    this.tui.addChild(this.modeline);
    this.tui.addChild(this.toolHint);

    // Focus the editor
    this.tui.setFocus(this.inputEditor);

    // Handle editor submit
    this.inputEditor.onSubmit = (text: string) => {
      if (this.store.getState().busy) {
        // Ignore input while agent is processing
        return;
      }
      this.inputEditor.addToHistory?.(text);
      this.handleInput(text);
      this.inputEditor.setText('');
    };

    const originalHandleInput = this.inputEditor.handleInput?.bind(this.inputEditor);
    this.inputEditor.handleInput = (data: string) => {
      if (matchesKey(data, 'ctrl+n')) {
        this.showNewSessionModal();
        return;
      }
      if (matchesKey(data, 'ctrl+tab')) {
        this.cycleSessions();
        return;
      }
      if (matchesKey(data, 'ctrl+o')) {
        if (this.hasToolOutputs()) {
          this.toggleToolPanel();
        }
        return;
      }
      if (matchesKey(data, 'ctrl+c')) {
        this.handleCtrlCInEditor();
        return;
      }
      if (matchesKey(data, 'escape')) {
        if (this.store.getState().busy) {
          this.handleEscAbortInEditor();
          return;
        }
      }
      originalHandleInput?.(data);
    };

    // Subscribe to state changes
    this.store.subscribe((state, prevState) => {
      this.onStateChange(state, prevState);
    });
  }

  private cycleSessions(): void {
    const state = this.store.getState();
    const sessionIds = Array.from(state.sessions.keys());

    if (sessionIds.length === 0) {
      this.showNewSessionModal();
      return;
    }

    if (!state.activeSessionId) {
      this.connection.setActiveSession(sessionIds[0]);
      return;
    }

    const currentIndex = sessionIds.indexOf(state.activeSessionId);
    const nextIndex =
      currentIndex === -1 ? 0 : (currentIndex + 1) % sessionIds.length;

    this.connection.setActiveSession(sessionIds[nextIndex]);
  }

  private handleCtrlCInEditor(): void {
    // If there's text in the editor, just clear it on first press
    const hasText = this.inputEditor.getText && this.inputEditor.getText().length > 0;

    if (hasText) {
      this.inputEditor.setText('');
      this.showCtrlCHint();
      return;
    }

    // If editor is already empty and this is the second press, quit
    if (this.ctrlCFirstPress) {
      this.stop();
      return;
    }

    // First press with empty editor - show hint
    this.showCtrlCHint();
  }

  private showCtrlCHint(): void {
    // Clear any existing timer
    if (this.ctrlCTimer) {
      clearTimeout(this.ctrlCTimer);
    }
    this.hideEscAbortHint();

    // Show or update the hint
    if (!this.ctrlCHint) {
      this.ctrlCHint = new Text(ansi.warning('Press Ctrl+C again to quit'), 1, 0);
      // Insert before the editor
      const children = this.tui.children;
      const editorIndex = children.indexOf(this.inputEditor);
      if (editorIndex > 0) {
        children.splice(editorIndex, 0, this.ctrlCHint);
      }
    } else {
      this.ctrlCHint.setText(ansi.warning('Press Ctrl+C again to quit'));
    }

    this.ctrlCFirstPress = true;
    this.tui.requestRender();

    // Set timer to clear the hint and reset state
    this.ctrlCTimer = setTimeout(() => {
      this.hideCtrlCHint();
    }, LemonTUI.CTRL_C_TIMEOUT_MS);
  }

  private hideCtrlCHint(): void {
    if (this.ctrlCTimer) {
      clearTimeout(this.ctrlCTimer);
      this.ctrlCTimer = null;
    }
    if (this.ctrlCHint) {
      this.tui.removeChild(this.ctrlCHint);
      this.ctrlCHint = null;
    }
    this.ctrlCFirstPress = false;
    this.tui.requestRender();
  }

  private handleEscAbortInEditor(): void {
    if (this.escAbortFirstPress) {
      this.hideEscAbortHint();
      this.connection.abort();
      return;
    }

    this.showEscAbortHint();
  }

  private showEscAbortHint(): void {
    if (this.escAbortTimer) {
      clearTimeout(this.escAbortTimer);
    }
    this.hideCtrlCHint();

    if (!this.escAbortHint) {
      this.escAbortHint = new Text(ansi.warning('Press Esc again to abort'), 1, 0);
      const children = this.tui.children;
      const editorIndex = children.indexOf(this.inputEditor);
      if (editorIndex > 0) {
        children.splice(editorIndex, 0, this.escAbortHint);
      }
    } else {
      this.escAbortHint.setText(ansi.warning('Press Esc again to abort'));
    }

    this.escAbortFirstPress = true;
    this.tui.requestRender();

    this.escAbortTimer = setTimeout(() => {
      this.hideEscAbortHint();
    }, LemonTUI.ESC_ABORT_TIMEOUT_MS);
  }

  private hideEscAbortHint(): void {
    if (this.escAbortTimer) {
      clearTimeout(this.escAbortTimer);
      this.escAbortTimer = null;
    }
    if (this.escAbortHint) {
      this.tui.removeChild(this.escAbortHint);
      this.escAbortHint = null;
    }
    this.escAbortFirstPress = false;
    this.tui.requestRender();
  }

  private setupEventHandlers(): void {
    // Connection events
    this.connection.on('ready', (msg) => {
      this.store.setReady(
        msg.cwd,
        msg.model,
        msg.ui,
        msg.debug,
        msg.primary_session_id,
        msg.active_session_id
      );
      this.updateSessionsHome();

      // Fetch running sessions (server may already have sessions)
      this.connection.listRunningSessions();

      // If a session file was provided via CLI, start it now
      if (this.connectionOptions.sessionFile) {
        this.pendingSessionAutoSwitch = true;
        this.connection.startSession({ sessionFile: this.connectionOptions.sessionFile });
        this.connectionOptions.sessionFile = undefined;
      }
    });

    this.connection.on('message', (msg) => {
      this.handleServerMessage(msg);
    });

    this.connection.on('error', (err) => {
      this.store.setError(err.message);
    });

    this.connection.on('close', (code) => {
      // If the agent intentionally exited to trigger a restart, transparently respawn it.
      if (code === AGENT_RESTART_EXIT_CODE) {
        void this.restartAgentConnection('Agent requested restart');
        return;
      }

      // During user-triggered restarts, we may see a close before the restart completes.
      if (this.agentRestartInFlight) {
        return;
      }

      this.store.setError(`Connection closed (code: ${code})`);
    });

    if (!this.processHandlersAttached) {
      // Handle Ctrl+C
      process.on('SIGINT', () => {
        if (this.store.getState().busy) {
          this.connection.abort();
        } else {
          this.stop();
        }
      });
      this.processHandlersAttached = true;
    }
  }

  private updateAutocompleteProvider(basePath: string): void {
    const normalized = basePath || process.cwd();
    if (this.autocompleteBasePath === normalized) {
      return;
    }
    this.autocompleteBasePath = normalized;
    this.inputEditor.setAutocompleteProvider(new CombinedAutocompleteProvider(slashCommands, normalized));
  }

  private ensureGitModeline(): void {
    if (this.gitRefreshTimer) {
      return;
    }
    this.refreshGitModeline();
    this.gitRefreshTimer = setInterval(() => {
      this.refreshGitModeline();
    }, GIT_REFRESH_INTERVAL_MS);
  }

  private async refreshGitModeline(): Promise<void> {
    if (this.gitRefreshInFlight) {
      return;
    }
    const cwd = this.store.getState().cwd || process.cwd();
    if (!cwd) {
      return;
    }
    if (this.gitCwd !== cwd) {
      this.gitCwd = cwd;
    }

    this.gitRefreshInFlight = true;
    try {
      const modeline = await getGitModeline(cwd);
      this.store.setStatus('modeline:git', modeline);
    } finally {
      this.gitRefreshInFlight = false;
    }
  }

  private handleServerMessage(msg: ServerMessage): void {
    switch (msg.type) {
      case 'event':
        // Pass session_id to route events to the correct session
        this.store.handleEvent(msg.event, msg.session_id);
        break;

      case 'stats':
        this.store.setStats(msg.stats, msg.session_id);
        break;

      case 'error':
        if (msg.session_id) {
          this.store.setError(`[${msg.session_id}] ${msg.message}`);
        } else {
          this.store.setError(msg.message);
        }
        break;

      case 'ui_request':
        this.handleUIRequest(msg);
        break;

      case 'ui_notify':
        this.handleUINotify(msg.params as { message: string; notify_type?: string; type?: string });
        break;

      case 'ui_status':
        this.handleUIStatus(msg.params as { key: string; text: string | null });
        break;

      case 'ui_working':
        this.store.setAgentWorkingMessage((msg.params as { message: string | null }).message);
        break;

      case 'ui_set_title':
        this.store.setTitle((msg.params as { title: string }).title);
        break;

      case 'ui_set_editor_text':
        this.inputEditor.setText((msg.params as { text: string }).text || '');
        break;

      case 'ui_widget':
        this.handleUIWidget(msg.params as { key: string; content: string | string[] | null; opts?: Record<string, unknown> });
        break;

      case 'save_result':
        this.handleSaveResult(msg as { type: 'save_result'; ok: boolean; path?: string; error?: string });
        break;

      case 'sessions_list':
        this.handleSessionsList(msg as { type: 'sessions_list'; sessions: SessionSummary[]; error?: string });
        break;

      // Session lifecycle messages
      case 'session_started':
        this.handleSessionStarted(msg);
        break;

      case 'session_closed':
        this.handleSessionClosed(msg);
        break;

      case 'running_sessions':
        this.handleRunningSessions(msg);
        break;

      case 'models_list':
        this.handleModelsList(msg as { type: 'models_list'; providers: Array<{ id: string; models: Array<{ id: string; name?: string }> }>; error?: string | null });
        break;

      case 'active_session':
        this.handleActiveSession(msg);
        break;

      case 'debug':
        // Display debug messages when debug mode is enabled
        if (this.store.getState().debug) {
          const debugMsg = msg as { message: string; argv?: string[] };
          this.messagesContainer.addChild(new Text(ansi.muted(`[debug] ${debugMsg.message}`), 1, 1));
          this.tui.requestRender();
        }
        break;
    }
  }

  private handleSessionStarted(msg: { type: 'session_started'; session_id: string; cwd: string; model: { provider: string; id: string } }): void {
    this.store.handleSessionStarted(msg.session_id, msg.cwd, msg.model);
    this.handleUINotify({
      message: `Session started: ${msg.session_id}`,
      notify_type: 'success',
    });
    if (this.pendingSessionAutoSwitch) {
      this.pendingSessionAutoSwitch = false;
      this.connection.setActiveSession(msg.session_id);
    }
    this.updateSessionsHome();
  }

  private handleSessionClosed(msg: { type: 'session_closed'; session_id: string; reason: string }): void {
    this.store.handleSessionClosed(msg.session_id, msg.reason);
    const notifyType = msg.reason === 'normal' ? 'info' : 'warning';
    this.handleUINotify({
      message: `Session closed: ${msg.session_id} (${msg.reason})`,
      notify_type: notifyType,
    });
    this.updateSessionsHome();
  }

  private handleRunningSessions(msg: { type: 'running_sessions'; sessions: RunningSessionInfo[]; error?: string | null }): void {
    if (msg.error) {
      this.store.setError(`Failed to list running sessions: ${msg.error}`);
      return;
    }
    this.store.setRunningSessions(msg.sessions);

    if (this.pendingRunningSessionsOverlay) {
      this.pendingRunningSessionsOverlay = false;
      this.showRunningSessionsOverlay(msg.sessions);
    } else {
      this.updateSessionsHome();
    }
  }

  private handleModelsList(msg: { type: 'models_list'; providers: Array<{ id: string; models: Array<{ id: string; name?: string }> }>; error?: string | null }): void {
    if (msg.error) {
      this.handleUINotify({
        message: `Failed to list models: ${msg.error}`,
        notify_type: 'error',
      });
      if (this.pendingModelSelection) {
        const { cwd } = this.pendingModelSelection;
        this.pendingModelSelection = null;
        this.showLocalInputOverlay(
          'Enter model (provider:model_id)',
          '',
          (modelSpec) => this.startSessionWithOptions(cwd, modelSpec || undefined)
        );
      }
      return;
    }

    this.modelCatalog = msg.providers;

    if (this.pendingModelSelection) {
      const { cwd } = this.pendingModelSelection;
      this.pendingModelSelection = null;
      this.showModelSelectionOverlay(cwd);
    }
  }

  private handleActiveSession(msg: { type: 'active_session'; session_id: string | null }): void {
    this.store.setActiveSessionId(msg.session_id);

    if (msg.session_id) {
      this.handleUINotify({
        message: `Active session: ${msg.session_id}`,
        notify_type: 'info',
      });
      // Update title to reflect active session
      const session = this.store.getSession(msg.session_id);
      if (session) {
        this.store.setTitle(`Lemon - ${session.model.id} [${msg.session_id.slice(0, 8)}]`);
      }
    } else {
      this.store.setTitle('Lemon');
      this.handleUINotify({
        message: 'No active session',
        notify_type: 'info',
      });
    }

    this.updateSessionsHome();

    if (msg.session_id && !this.currentOverlayRequestId) {
      this.tui.setFocus(this.inputEditor);
    }
  }

  private updateSessionsHome(): void {
    const state = this.store.getState();

    this.sessionsContainer.clear();
    this.sessionsList = null;

    if (!state.ready) {
      return;
    }

    if (state.activeSessionId) {
      return;
    }

    const items: SelectItem[] = [];
    for (const session of state.sessions.values()) {
      const shortId = session.sessionId.slice(0, 8);
      const label = `${shortId} • ${session.model.id}`;
      items.push({
        label,
        value: session.sessionId,
        description: session.cwd,
      });
    }

    items.push({
      label: '➕ New session',
      value: '__new__',
      description: 'Start a new session',
    });

    const title = new Text(ansi.bold('Active Sessions'), 1, 0);
    const list = new SelectList(items, Math.min(10, items.length), selectListTheme);

    list.onSelect = (item: SelectItem) => {
      if (item.value === '__new__') {
        this.showNewSessionModal();
      } else {
        this.connection.setActiveSession(item.value as string);
      }
    };

    list.onCancel = () => {
      // Keep focus on the list when no session is active
      this.tui.setFocus(list);
    };

    this.sessionsContainer.addChild(title);
    this.sessionsContainer.addChild(list);
    this.sessionsList = list;

    if (!this.currentOverlayRequestId) {
      this.tui.setFocus(list);
    }
  }

  private showRunningSessionsOverlay(sessions: RunningSessionInfo[]): void {
    if (sessions.length === 0) {
      // Still allow creating a new session
      const items: SelectItem[] = [
        { label: '➕ New session', value: '__new__', description: 'Start a new session' },
      ];
      this.showLocalSelectOverlay('Running Sessions', items, (item) => {
        if (item.value === '__new__') {
          this.showNewSessionModal();
        }
      });
      return;
    }

    const items: SelectItem[] = sessions.map((s) => ({
      label: `${s.session_id.slice(0, 12)}${s.is_streaming ? ' (streaming)' : ''}`,
      value: s.session_id,
      description: s.cwd,
    }));
    items.push({ label: '➕ New session', value: '__new__', description: 'Start a new session' });

    this.showLocalSelectOverlay('Running Sessions (select to switch)', items, (item) => {
      if (item.value === '__new__') {
        this.showNewSessionModal();
      } else {
        this.connection.setActiveSession(item.value as string);
      }
    });
  }

  private getRecentDirectories(): string[] {
    const seen = new Set<string>();
    const recent: string[] = [];

    // Most recent saved sessions first
    for (const session of this.lastSessions) {
      if (session.cwd && !seen.has(session.cwd)) {
        seen.add(session.cwd);
        recent.push(session.cwd);
      }
    }

    // Running sessions
    for (const session of this.store.getState().sessions.values()) {
      if (session.cwd && !seen.has(session.cwd)) {
        seen.add(session.cwd);
        recent.push(session.cwd);
      }
    }

    return recent;
  }

  private showNewSessionModal(opts?: { cwd?: string; model?: string }): void {
    const recentDirs = this.getRecentDirectories();
    const defaultCwd =
      opts?.cwd ?? this.store.getState().cwd ?? this.connectionOptions.cwd ?? '';
    const defaultModel = opts?.model;

    this.showLocalPathInputOverlay(
      'New session: working directory',
      defaultCwd,
      recentDirs,
      (cwd) => {
        if (!cwd) {
          return;
        }
        this.showModelSelectionOverlay(cwd, defaultModel);
      }
    );
  }

  private showModelSelectionOverlay(cwd: string, defaultModelSpec?: string): void {
    if (defaultModelSpec) {
      this.startSessionWithOptions(cwd, defaultModelSpec);
      return;
    }

    if (!this.modelCatalog) {
      this.pendingModelSelection = { cwd };
      this.connection.listModels();
      return;
    }

    this.showModelProviderOverlay(cwd);
  }

  private showModelProviderOverlay(cwd: string): void {
    const state = this.store.getState();
    const currentModel = state.model?.provider
      ? `${state.model.provider}:${state.model.id}`
      : state.model?.id || 'default';

    const providers = this.modelCatalog ?? [];
    if (providers.length === 0) {
      this.showLocalInputOverlay(
        'Enter model (provider:model_id)',
        currentModel,
        (modelSpec) => this.startSessionWithOptions(cwd, modelSpec || undefined)
      );
      return;
    }

    const items: SelectItem[] = [
      {
        label: `Default (${currentModel})`,
        value: '__default__',
        description: 'Use server default',
      },
      {
        label: 'Custom model…',
        value: '__custom__',
        description: 'Enter provider:model_id',
      },
    ];
    for (const provider of providers) {
      items.push({
        label: provider.id,
        value: provider.id,
        description: `${provider.models.length} models`,
      });
    }

    this.showLocalSelectOverlay('Select provider', items, (item) => {
      if (item.value === '__custom__') {
        this.showLocalInputOverlay(
          'Enter model (provider:model_id)',
          currentModel,
          (modelSpec) => this.startSessionWithOptions(cwd, modelSpec || undefined)
        );
        return;
      }

      if (item.value === '__default__') {
        this.startSessionWithOptions(cwd, undefined);
        return;
      }

      this.showModelListOverlay(cwd, item.value as string);
    });
  }

  private showModelListOverlay(cwd: string, providerId: string): void {
    const provider = this.modelCatalog?.find((p) => p.id === providerId);
    if (!provider) {
      this.showModelProviderOverlay(cwd);
      return;
    }

    const items: SelectItem[] = [
      { label: 'Back', value: '__back__', description: 'Choose a different provider' },
      { label: 'Custom model…', value: '__custom__', description: 'Enter provider:model_id' },
    ];

    for (const model of provider.models) {
      const label = model.name ? `${model.id} - ${model.name}` : model.id;
      items.push({
        label,
        value: model.id,
        description: providerId,
      });
    }

    this.showLocalSelectOverlay(`Select model (${providerId})`, items, (item) => {
      if (item.value === '__back__') {
        this.showModelProviderOverlay(cwd);
        return;
      }
      if (item.value === '__custom__') {
        this.showLocalInputOverlay(
          'Enter model (provider:model_id)',
          `${providerId}:`,
          (modelSpec) => this.startSessionWithOptions(cwd, modelSpec || undefined)
        );
        return;
      }

      this.startSessionWithOptions(cwd, `${providerId}:${item.value as string}`);
    });
  }

  private startSessionWithOptions(cwd: string, modelSpec?: string): void {
    this.pendingSessionAutoSwitch = true;
    this.connection.startSession({
      cwd,
      model: modelSpec,
    });
  }

  private handleInput(text: string): void {
    const trimmed = text.trim();

    if (!trimmed) {
      return;
    }

    // Handle commands
    if (trimmed.startsWith('/')) {
      const [cmd, ...args] = trimmed.slice(1).split(/\s+/);
      this.handleCommand(cmd, args);
      return;
    }

    // Send as prompt to the active session
    const activeSessionId = this.store.getState().activeSessionId;
    if (!activeSessionId) {
      this.showNewSessionModal();
      return;
    }
    this.connection.prompt(trimmed, activeSessionId);
  }

  private handleCommand(cmd: string, args: string[]): void {
    switch (cmd.toLowerCase()) {
      case 'abort':
        this.connection.abort();
        break;

      case 'reset':
        this.connection.reset();
        this.store.resetActiveSession();
        this.clearMessages();
        break;

      case 'save':
        this.connection.save();
        break;

      case 'sessions':
        this.connection.listSessions();
        break;

      case 'resume':
        if (args.length > 0) {
          this.resumeFromArg(args.join(' '));
        } else {
          this.connection.listSessions();
        }
        break;

      case 'stats':
        this.connection.stats();
        break;

      case 'search':
        this.showSearchResults(args.join(' '));
        break;

      case 'settings':
        this.showSettingsOverlay();
        break;

      case 'debug': {
        // Toggle or set debug mode
        const arg = args[0]?.toLowerCase();
        const state = this.store.getState();
        let newDebug: boolean;
        if (arg === 'on') {
          newDebug = true;
        } else if (arg === 'off') {
          newDebug = false;
        } else {
          newDebug = !state.debug;
        }
        this.store.setDebug(newDebug);
        this.messagesContainer.addChild(
          new Text(ansi.muted(`[debug] Debug mode ${newDebug ? 'enabled' : 'disabled'}`), 1, 1)
        );
        this.tui.requestRender();
        break;
      }

      case 'restart':
        void this.restartAgentConnection(args.join(' ') || 'User requested restart');
        break;

      case 'quit':
      case 'exit':
      case 'q':
        this.stop();
        break;

      case 'help':
        this.showHelp();
        break;

      // Multi-session commands
      case 'running':
        this.pendingRunningSessionsOverlay = true;
        this.connection.listRunningSessions();
        break;

      case 'new-session':
        this.startNewSession(args);
        break;

      case 'switch':
        if (args.length > 0) {
          this.connection.setActiveSession(args[0]);
        } else {
          // Show running sessions overlay to select
          this.connection.listRunningSessions();
        }
        break;

      case 'close-session': {
        const state = this.store.getState();
        const sessionToClose = args[0] || state.activeSessionId;
        if (sessionToClose) {
          this.connection.closeSession(sessionToClose);
        } else {
          this.store.setError('No session to close');
        }
        break;
      }

      default:
        this.store.setError(`Unknown command: /${cmd}`);
    }
  }

  private startNewSession(args: string[]): void {
    // Parse optional arguments: /new-session [--cwd <path>] [--model <model>]
    const opts: { cwd?: string; model?: string } = {};
    for (let i = 0; i < args.length; i++) {
      if (args[i] === '--cwd' && args[i + 1]) {
        opts.cwd = args[++i];
      } else if (args[i] === '--model' && args[i + 1]) {
        opts.model = args[++i];
      }
    }
    this.showNewSessionModal(opts);
  }

  private showHelp(): void {
    const helpText = `${ansi.bold('Commands:')}
  /abort         - Stop the current operation
  /reset         - Clear conversation and reset session
  /save          - Save the current session
  /sessions      - List saved sessions
  /resume        - Resume a saved session
  /stats         - Show session statistics
  /search        - Search for text in conversations
  /settings      - Open settings
  /debug         - Toggle debug mode (on/off)
  /restart       - Restart the Lemon agent process (reload latest code)
  /quit          - Exit the application
  /help          - Show this help message

${ansi.bold('Multi-Session:')}
  /running       - List running sessions
  /new-session   - Start a new session [--cwd <path>] [--model <model>]
  /switch [id]   - Switch to a different session (or show list)
  /close-session - Close the current session

${ansi.bold('Shortcuts:')}
  Enter         - Send message
  Shift+Enter   - New line in editor
  Ctrl+N        - New session
  Ctrl+Tab      - Cycle sessions
  Ctrl+C        - Clear input (press twice to quit)
  Esc (x2)      - Abort current operation
  Escape        - Cancel overlay dialogs`;

    this.messagesContainer.addChild(new Text(helpText, 1, 1));
    this.tui.requestRender();
  }

  private async restartAgentConnection(reason: string): Promise<void> {
    if (this.agentRestartInFlight) {
      return;
    }
    this.agentRestartInFlight = true;

    try {
      // Cancel any overlay that might be waiting for a ui_response from a soon-to-die process.
      this.hideOverlay();
      this.store.setPendingUIRequest(null);

      this.handleUINotify({ message: `Restarting agent: ${reason}`, notify_type: 'warning' });

      // Clear state so we don't render stale sessions/messages while reconnecting.
      this.store.reset();

      await this.connection.restart();
      this.handleUINotify({ message: 'Agent restarted', notify_type: 'success' });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      this.store.setError(`Failed to restart agent: ${msg}`);
    } finally {
      this.agentRestartInFlight = false;
    }
  }

  private clearMessages(): void {
    this.messagesContainer.clear();
    this.tui.requestRender();
  }

  private showSearchResults(query: string): void {
    if (!query.trim()) {
      this.store.setError('Usage: /search <term>');
      return;
    }

    const messages = this.store.getState().messages;
    const queryLower = query.toLowerCase();
    const matches: { type: string; content: string; index: number }[] = [];

    for (let i = 0; i < messages.length; i++) {
      const msg = messages[i];
      let content = '';

      if (msg.type === 'user') {
        content = msg.content;
      } else if (msg.type === 'assistant') {
        const assistant = msg as NormalizedAssistantMessage;
        content = assistant.textContent || '';
      } else if (msg.type === 'tool_result') {
        content = msg.content;
      }

      if (content.toLowerCase().includes(queryLower)) {
        matches.push({ type: msg.type, content, index: i });
      }
    }

    if (matches.length === 0) {
      this.messagesContainer.addChild(new Text(ansi.muted(`No results found for "${query}"`), 1, 1));
    } else {
      this.messagesContainer.addChild(new Text(ansi.bold(`Search results for "${query}" (${matches.length} matches):`), 1, 1));

      for (const match of matches) {
        const roleLabel = match.type === 'user' ? 'You' : match.type === 'assistant' ? 'Assistant' : 'Tool';
        const preview = match.content.slice(0, 200).replace(/\n/g, ' ');

        // Highlight the search term in the preview
        const highlighted = preview.replace(
          new RegExp(`(${query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')})`, 'gi'),
          (m) => ansi.warning(m)
        );

        this.messagesContainer.addChild(
          new Text(`${ansi.muted(`[${match.index}]`)} ${ansi.primary(roleLabel)}: ${highlighted}${match.content.length > 200 ? '...' : ''}`, 1, 0)
        );
      }
    }

    this.tui.requestRender();
  }

  private updateHeader(): void {
    const state = this.store.getState();
    const modelInfo = state.ready
      ? `${ansi.primary(`${state.model.provider}:${state.model.id}`)}`
      : ansi.muted('connecting...');

    const cwdShort = state.cwd.replace(process.env.HOME || '', '~');
    this.header.setText(`${ansi.bold('Lemon')} ${modelInfo}\n${ansi.muted(cwdShort)}`);
  }

  private updateWelcomeSection(): void {
    if (!this.welcomeVisible) {
      this.welcomeSection.setText('');
      return;
    }

    const state = this.store.getState();
    const lemon = getLemonArt();
    const cwdShort = state.cwd ? state.cwd.replace(process.env.HOME || '', '~') : process.cwd().replace(process.env.HOME || '', '~');

    const lines = [
      '',
      lemon,
      '',
      ansi.bold('  Welcome to Lemon!'),
      '',
      `  ${ansi.muted('cwd')}     ${ansi.secondary(cwdShort)}`,
    ];

    if (state.ready) {
      lines.push(`  ${ansi.muted('model')}   ${ansi.secondary(`${state.model.provider}:${state.model.id}`)}`);
    } else {
      lines.push(`  ${ansi.muted('model')}   ${ansi.dim('connecting...')}`);
    }

    lines.push('');
    lines.push(`  ${ansi.muted('Type a message to get started, or')} ${ansi.primary('/help')} ${ansi.muted('for commands.')}`);
    lines.push('');

    this.welcomeSection.setText(lines.join('\n'));
  }

  private hideWelcomeSection(): void {
    if (this.welcomeVisible) {
      this.welcomeVisible = false;
      this.welcomeSection.setText('');
      this.tui.requestRender();
    }
  }

  private updateStatusBar(): void {
    const state = this.store.getState();
    const parts: string[] = [];

    // Busy indicator
    if (state.busy) {
      parts.push(ansi.primary('●'));
    }

    // Working message (agent working message takes priority over tool working message)
    const workingMessage = state.agentWorkingMessage || state.toolWorkingMessage;
    if (workingMessage) {
      parts.push(ansi.muted(workingMessage));
    }

    // UI status entries (from ui_status signals)
    for (const [key, value] of state.status) {
      if (value && !this.isModelineKey(key)) {
        parts.push(ansi.secondary(`${key}: ${value}`));
      }
    }

    // Token and cost display
    const usage = state.cumulativeUsage;
    if (usage.inputTokens > 0 || usage.outputTokens > 0) {
      const inTokens = this.formatTokenCount(usage.inputTokens);
      const outTokens = this.formatTokenCount(usage.outputTokens);
      let tokenPart = `tokens: ${inTokens} in, ${outTokens} out`;
      if (usage.totalCost > 0) {
        tokenPart += ` | $${usage.totalCost.toFixed(2)}`;
      }
      parts.push(ansi.muted(tokenPart));
    }

    // Stats
    if (state.stats) {
      parts.push(
        ansi.muted(`turns: ${state.stats.turn_count} | msgs: ${state.stats.message_count}`)
      );
    }

    // Error
    if (state.error) {
      parts.push(ansi.error(`Error: ${state.error}`));
    }

    this.statusBar.setText(parts.length > 0 ? parts.join(' | ') : ' ');
  }

  private updateModeline(): void {
    const state = this.store.getState();
    const parts: string[] = [];

    // Show session info if there are multiple sessions
    const sessionCount = state.sessions.size;
    if (sessionCount > 1 && state.activeSessionId) {
      const shortId = state.activeSessionId.slice(0, 8);
      parts.push(ansi.primary(`session: ${shortId} (${sessionCount})`));
    }

    for (const [key, value] of state.status) {
      if (!value) {
        continue;
      }
      const formatted = this.formatModelineEntry(key, value);
      if (formatted) {
        parts.push(formatted);
      }
    }

    // If no modeline entries, show the current directory as a default
    if (parts.length === 0) {
      const cwdShort = state.cwd.replace(process.env.HOME || '', '~');
      parts.push(ansi.secondary(cwdShort));
    }

    const content = ` ${parts.join(' | ')} `;
    // Pad to full terminal width for background effect
    const termWidth = process.stdout.columns || 80;
    // Strip ANSI codes to get actual visible length
    const visibleLength = content.replace(/\x1b\[[0-9;]*m/g, '').length;
    const padded = content + ' '.repeat(Math.max(0, termWidth - visibleLength));
    this.modeline.setText(ansi.modelineBg(padded));
  }

  private isModelineKey(key: string): boolean {
    if (key === 'modeline') {
      return true;
    }
    return MODELINE_PREFIXES.some((prefix) => key.startsWith(prefix));
  }

  private formatModelineEntry(key: string, value: string): string | null {
    if (key === 'modeline') {
      return ansi.secondary(value);
    }
    const prefix = MODELINE_PREFIXES.find((candidate) => key.startsWith(candidate));
    if (!prefix) {
      return null;
    }
    const label = key.slice(prefix.length).trim();
    if (!label) {
      return ansi.secondary(value);
    }
    return ansi.secondary(`${label}: ${value}`);
  }

  private formatTokenCount(count: number): string {
    if (count >= 1000000) {
      return `${(count / 1000000).toFixed(1)}M`;
    } else if (count >= 1000) {
      return `${(count / 1000).toFixed(1)}k`;
    }
    return count.toString();
  }

  private updateToolExecutionBar(): void {
    const state = this.store.getState();
    const activeTools: string[] = [];

    for (const [, tool] of state.toolExecutions) {
      if (!tool.endTime) {
        // Tool is still running
        const elapsed = Math.floor((Date.now() - tool.startTime) / 1000);

        if (tool.name === 'task' && tool.taskEngine) {
          // Enhanced display for Task tool with engine and current action
          const engine = tool.taskEngine;
          const actionInfo = tool.taskCurrentAction
            ? ` → ${tool.taskCurrentAction.title}`
            : '';
          activeTools.push(
            `${ansi.warning('▶')} task[${ansi.secondary(engine)}]${actionInfo} (${elapsed}s)`
          );
        } else {
          // Standard display for other tools
          activeTools.push(`${ansi.warning('▶')} ${tool.name} (${elapsed}s)`);
        }
      }
    }

    if (activeTools.length > 0) {
      this.toolExecutionBar.setText(activeTools.join(' | '));
    } else {
      this.toolExecutionBar.setText('');
    }
  }

  private updateToolExecutionTimer(): void {
    const state = this.store.getState();
    const hasRunningTool = Array.from(state.toolExecutions.values()).some((tool) => !tool.endTime);

    if (hasRunningTool && !this.toolExecutionTimer) {
      this.toolExecutionTimer = setInterval(() => {
        this.updateToolExecutionBar();
        this.updateToolPanel();
        this.updateToolHint();
        this.tui.requestRender();
      }, 1000);
    } else if (!hasRunningTool && this.toolExecutionTimer) {
      clearInterval(this.toolExecutionTimer);
      this.toolExecutionTimer = null;
    }
  }

  private updateToolPanel(): void {
    const state = this.store.getState();
    const tools = Array.from(state.toolExecutions.values());

    this.toolPanel.clear();

    if (tools.length === 0 || this.toolPanelCollapsed) {
      return;
    }

    // Show newest tools first
    const sorted = tools.sort((a, b) => b.startTime - a.startTime).slice(0, 4);

    this.toolPanel.addChild(new Text(ansi.muted('[tools]'), 1, 0));

    for (const tool of sorted) {
      const isRunning = !tool.endTime;
      const isError = Boolean(tool.isError);
      const statusIcon = isRunning
        ? ansi.warning('▶')
        : isError
        ? ansi.error('✗')
        : ansi.success('✓');
      const durationMs = (tool.endTime ?? Date.now()) - tool.startTime;
      const duration = `${Math.max(0, Math.floor(durationMs / 1000))}s`;

      const title = `${statusIcon} ${ansi.bold(tool.name)} ${ansi.muted(`(${duration})`)}`;
      this.toolPanel.addChild(new Text(title, 1, 0));

      // For Task tools, show enhanced info (engine and current action)
      if (tool.name === 'task') {
        if (tool.taskEngine) {
          this.toolPanel.addChild(
            new Text(ansi.muted(`  engine: ${tool.taskEngine}`), 1, 0)
          );
        }

        if (tool.taskCurrentAction) {
          const action = tool.taskCurrentAction;
          const phaseIcon =
            action.phase === 'started'
              ? '▶'
              : action.phase === 'completed'
              ? '✓'
              : '…';
          this.toolPanel.addChild(
            new Text(ansi.secondary(`  ${phaseIcon} ${action.title}`), 1, 0)
          );
        }
      }

      const argsText = this.formatToolArgs(tool.args, tool.name);
      if (argsText) {
        this.toolPanel.addChild(new Text(ansi.muted(`  args: ${argsText}`), 1, 0));
      }

      const resultPayload = tool.result ?? tool.partialResult;
      if (resultPayload !== undefined) {
        const label = tool.result ? '  result:' : '  partial:';
        const resultText = this.formatToolResult(resultPayload, tool.name, tool.args);
        if (resultText) {
          this.toolPanel.addChild(new Text(ansi.secondary(`${label} ${resultText}`), 1, 0));
        }
      }

      this.toolPanel.addChild(new Text('', 1, 0));
    }
  }

  private updateToolHint(): void {
    if (!this.hasToolOutputs()) {
      this.toolHint.setText('');
      return;
    }

    const hint = this.toolPanelCollapsed
      ? 'Ctrl+O to show tool output'
      : 'Ctrl+O to hide tool output';
    this.toolHint.setText(ansi.muted(hint));
  }

  private updateWidgets(): void {
    const state = this.store.getState();

    // Clear existing widgets
    this.widgetsContainer.clear();

    // Render each widget
    for (const [key, widget] of state.widgets) {
      const header = new Text(ansi.muted(`[${key}]`), 1, 0);
      this.widgetsContainer.addChild(header);
      for (const line of widget.content) {
        this.widgetsContainer.addChild(new Text(ansi.muted(line), 1, 0));
      }
    }

    this.tui.requestRender();
  }

  private renderMessages(): void {
    const state = this.store.getState();
    this.streamingComponent = this.messageRenderer.renderMessages(
      this.messagesContainer,
      state.messages,
      state.streamingMessage
    );
  }

  private onStateChange(state: AppState, prevState: AppState): void {
    // Update header
    if (state.ready !== prevState.ready || state.model !== prevState.model) {
      this.updateHeader();
      // Also update welcome section when model info changes
      if (this.welcomeVisible) {
        this.updateWelcomeSection();
      }
    }

    // Hide welcome section when first message arrives
    if (this.welcomeVisible && state.messages.length > 0 && prevState.messages.length === 0) {
      this.hideWelcomeSection();
    }

    // Update status bar
    this.updateStatusBar();
    this.updateModeline();

    // Update tool execution bar
    if (state.toolExecutions !== prevState.toolExecutions) {
      this.updateToolExecutionBar();
      this.updateToolPanel();
      this.updateToolHint();
      this.updateToolExecutionTimer();
    }

    // Update widgets
    if (state.widgets !== prevState.widgets) {
      this.updateWidgets();
    }

    // Update messages
    if (state.messages.length !== prevState.messages.length) {
      this.renderMessages();
    } else if (state.streamingMessage !== prevState.streamingMessage) {
      this.updateStreamingMessage(state.streamingMessage);
    }

    // Update loader + input submit disabling
    if (state.busy !== prevState.busy) {
      this.updateLoader(state.busy);
      // Prevent accidental submits while the agent is streaming/processing.
      // (We still guard in onSubmit, but this improves UX by disabling submit at the component level.)
      this.inputEditor.disableSubmit = state.busy;
    }

    // Update terminal title using pi-tui's terminal interface
    if (state.title !== prevState.title) {
      this.tui.terminal.setTitle(state.title);
    }

    if (state.ready && !prevState.ready) {
      this.ensureGitModeline();
    }

    if (state.cwd !== prevState.cwd) {
      this.refreshGitModeline();
    }

    if (state.cwd !== prevState.cwd || (state.ready && !prevState.ready)) {
      const basePath = state.cwd || process.cwd();
      this.updateAutocompleteProvider(basePath);
    }

    if (prevState.busy && !state.busy) {
      this.hideEscAbortHint();
    }

    if (
      state.activeSessionId !== prevState.activeSessionId ||
      state.sessions !== prevState.sessions
    ) {
      this.updateSessionsHome();
    }

    // Handle pending UI request queue
    const currentRequest = this.store.getCurrentUIRequest();
    const wasShowingOverlay = this.currentOverlayRequestId !== null;

    // If there's a request in the queue and we're not showing an overlay, show it
    if (currentRequest && !wasShowingOverlay) {
      this.showUIOverlay(currentRequest);
    }

    this.tui.requestRender();
  }

  private updateStreamingMessage(message: NormalizedAssistantMessage | null): void {
    this.streamingComponent = this.messageRenderer.updateStreamingMessage(
      this.messagesContainer,
      this.streamingComponent,
      message
    );
  }

  private hasToolOutputs(): boolean {
    return this.store.getState().toolExecutions.size > 0;
  }

  private toggleToolPanel(): void {
    this.toolPanelCollapsed = !this.toolPanelCollapsed;
    this.updateToolPanel();
    this.updateToolHint();
    this.renderMessages();
    this.tui.requestRender();
  }

  private formatToolArgs(args: Record<string, unknown>, toolName?: string): string {
    return this.messageRenderer.formatToolArgs(args, toolName);
  }

  private formatToolResult(result: unknown, toolName?: string, args?: Record<string, unknown>): string {
    return this.messageRenderer.formatToolResult(result, toolName, args);
  }

  private updateLoader(busy: boolean): void {
    if (busy && !this.loader) {
      this.loader = new Loader(this.tui, ansi.primary, ansi.muted, 'Processing...');
      // Insert before the editor
      const children = this.tui.children;
      const editorIndex = children.indexOf(this.inputEditor);
      if (editorIndex > 0) {
        children.splice(editorIndex, 0, this.loader);
      }
    } else if (!busy && this.loader) {
      this.tui.removeChild(this.loader);
      this.loader.stop();
      this.loader = null;
    }
  }

  // ============================================================================
  // UI Overlays
  // ============================================================================

  private handleUIRequest(request: UIRequestMessage): void {
    this.store.enqueueUIRequest(request);
  }

  private handleUIWidget(params: { key: string; content: string | string[] | null; opts?: Record<string, unknown> }): void {
    this.store.setWidget(params.key, params.content, params.opts || {});
  }

  private showUIOverlay(request: UIRequestMessage): void {
    this.overlayManager.showUIOverlay(request);
  }

  private hideOverlay(): void {
    this.overlayManager.hideOverlay();
  }

  private showLocalSelectOverlay(
    title: string,
    items: SelectItem[],
    onSelect: (item: SelectItem) => void
  ): void {
    this.overlayManager.showLocalSelectOverlay(title, items, onSelect);
  }

  private showLocalInputOverlay(
    title: string,
    prefill: string,
    onSubmit: (value: string) => void
  ): void {
    this.overlayManager.showLocalInputOverlay(title, prefill, onSubmit);
  }

  private showLocalPathInputOverlay(
    title: string,
    prefill: string,
    recentDirectories: string[],
    onSubmit: (value: string) => void
  ): void {
    this.overlayManager.showLocalPathInputOverlay(title, prefill, recentDirectories, onSubmit);
  }

  private hideLocalOverlay(): void {
    this.overlayManager.hideLocalOverlay();
  }

  private showSettingsOverlay(): void {
    this.overlayManager.showSettingsOverlay();
  }

  private hideSettingsOverlay(): void {
    this.overlayManager.hideSettingsOverlay();
  }

  private handleUINotify(params: { message: string; notify_type?: string; type?: string }): void {
    // Support both notify_type (from DebugRPC) and type (fallback)
    const notifyType = params.notify_type || params.type || 'info';
    const colorFn =
      notifyType === 'error'
        ? ansi.error
        : notifyType === 'warning'
        ? ansi.warning
        : notifyType === 'success'
        ? ansi.success
        : ansi.secondary;

    this.messagesContainer.addChild(new Text(colorFn(`[${notifyType}] ${params.message}`), 1, 1));
    this.tui.requestRender();
  }

  private handleUIStatus(params: { key: string; text: string | null }): void {
    this.store.setStatus(params.key, params.text);
  }

  private handleSaveResult(msg: { ok: boolean; path?: string; error?: string }): void {
    if (msg.ok && msg.path) {
      this.handleUINotify({ message: `Saved session to ${msg.path}`, notify_type: 'success' });
    } else if (msg.ok) {
      this.handleUINotify({ message: 'Session saved', notify_type: 'success' });
    } else {
      this.handleUINotify({ message: `Save failed: ${msg.error || 'unknown error'}`, notify_type: 'error' });
    }
  }

  private handleSessionsList(msg: { sessions: SessionSummary[]; error?: string }): void {
    if (msg.error) {
      this.handleUINotify({ message: `Failed to list sessions: ${msg.error}`, notify_type: 'error' });
      return;
    }

    this.lastSessions = msg.sessions;

    if (msg.sessions.length === 0) {
      this.handleUINotify({ message: 'No saved sessions found', notify_type: 'info' });
      return;
    }

    const items: SelectItem[] = msg.sessions.map((session) => {
      const time = new Date(session.timestamp).toLocaleString();
      return {
        label: `${time} - ${session.id}`,
        value: session.path,
        description: session.cwd,
      };
    });

    this.showLocalSelectOverlay('Resume session', items, (item) => {
      this.resumeSession(item.value as string);
    });
  }

  private resumeFromArg(arg: string): void {
    const trimmed = arg.trim();
    if (!trimmed) {
      this.connection.listSessions();
      return;
    }

    const match = this.lastSessions.find((session) => session.id === trimmed);
    if (match) {
      this.resumeSession(match.path);
      return;
    }

    this.resumeSession(trimmed);
  }

  private async resumeSession(sessionFile: string): Promise<void> {
    if (!sessionFile) {
      return;
    }
    this.pendingSessionAutoSwitch = true;
    this.connection.startSession({ sessionFile });
  }

  // ============================================================================
  // Lifecycle
  // ============================================================================

  async start(): Promise<void> {
    console.log('Starting Lemon TUI...');

    try {
      await this.connection.start();
      this.tui.start();
    } catch (err) {
      console.error('Failed to start:', err);
      process.exit(1);
    }
  }

  stop(): void {
    if (this.loader) {
      this.loader.stop();
    }
    if (this.gitRefreshTimer) {
      clearInterval(this.gitRefreshTimer);
      this.gitRefreshTimer = null;
    }
    if (this.ctrlCTimer) {
      clearTimeout(this.ctrlCTimer);
      this.ctrlCTimer = null;
    }
    if (this.escAbortTimer) {
      clearTimeout(this.escAbortTimer);
      this.escAbortTimer = null;
    }
    if (this.toolExecutionTimer) {
      clearInterval(this.toolExecutionTimer);
      this.toolExecutionTimer = null;
    }
    this.tui.stop();
    this.connection.stop();
    process.exit(0);
  }
}
