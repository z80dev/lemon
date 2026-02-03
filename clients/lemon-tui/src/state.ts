/**
 * State management for the TUI client.
 *
 * Tracks messages, tool executions, and UI state.
 */

import type {
  Message,
  AssistantMessage,
  UserMessage,
  ToolResultMessage,
  ContentBlock,
  SessionEvent,
  SessionStats,
  UIRequestMessage,
  RunningSessionInfo,
} from './types.js';

export interface ToolExecution {
  id: string;
  name: string;
  args: Record<string, unknown>;
  partialResult?: unknown;
  result?: unknown;
  isError?: boolean;
  startTime: number;
  endTime?: number;

  // Task tool specific fields (parsed from partialResult details)
  taskEngine?: string;
  taskCurrentAction?: {
    title: string;
    kind: string;
    phase: string;
  };
}

/** Cumulative token and cost tracking */
export interface CumulativeUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  totalCost: number;
}

/**
 * Per-session state - contains all state that is session-scoped.
 * When multi-session support is active, each session has its own SessionState.
 */
export interface SessionState {
  /** Session ID */
  sessionId: string;
  /** Working directory for this session */
  cwd: string;
  /** Model info for this session */
  model: { provider: string; id: string };
  /** All messages in this session's conversation */
  messages: NormalizedMessage[];
  /** Currently streaming assistant message (null if not streaming) */
  streamingMessage: NormalizedAssistantMessage | null;
  /** Active tool executions for this session */
  toolExecutions: Map<string, ToolExecution>;
  /** Session is processing */
  busy: boolean;
  /** Session stats */
  stats: SessionStats | null;
  /** Cumulative token and cost usage for this session */
  cumulativeUsage: CumulativeUsage;
  /** Tool working message for this session */
  toolWorkingMessage: string | null;
  /** Agent working message for this session */
  agentWorkingMessage: string | null;
  /** Widget content by key for this session */
  widgets: Map<string, { content: string[]; opts: Record<string, unknown> }>;
  /** Is this session currently streaming from the server */
  isStreaming: boolean;
}

/**
 * Running session info from the server.
 */
export interface RunningSession {
  sessionId: string;
  cwd: string;
  isStreaming: boolean;
}

export interface AppState {
  /** Connection ready state */
  ready: boolean;
  /** UI support enabled */
  ui: boolean;
  /** Debug mode enabled */
  debug: boolean;
  /** Current status line values (global) */
  status: Map<string, string | null>;
  /** Window title */
  title: string;
  /** Pending UI requests queue (overlays) */
  pendingUIRequests: UIRequestMessage[];
  /** Error message to display */
  error: string | null;

  // ============================================================================
  // Multi-session state
  // ============================================================================

  /** Primary session ID (the session started when RPC boots) */
  primarySessionId: string | null;
  /** Active session ID (the default session for commands without session_id) */
  activeSessionId: string | null;
  /** All running sessions by session_id */
  sessions: Map<string, SessionState>;
  /** List of running sessions from server (for UI display) */
  runningSessions: RunningSession[];

  // ============================================================================
  // Active session convenience accessors (for backward compatibility)
  // These reference the active session's state
  // ============================================================================

  /** Current working directory (active session) */
  cwd: string;
  /** Model info (active session) */
  model: { provider: string; id: string };
  /** All messages in the conversation (active session) */
  messages: NormalizedMessage[];
  /** Currently streaming assistant message (active session) */
  streamingMessage: NormalizedAssistantMessage | null;
  /** Active tool executions (active session) */
  toolExecutions: Map<string, ToolExecution>;
  /** Agent is processing (active session) */
  busy: boolean;
  /** Session stats (active session) */
  stats: SessionStats | null;
  /** Cumulative token and cost usage (active session) */
  cumulativeUsage: CumulativeUsage;
  /** Tool working message (active session) */
  toolWorkingMessage: string | null;
  /** Agent working message (active session) */
  agentWorkingMessage: string | null;
  /** Widget content by key (active session) */
  widgets: Map<string, { content: string[]; opts: Record<string, unknown> }>;
}

// ============================================================================
// Normalized Message Types
// ============================================================================

export interface NormalizedUserMessage {
  id: string;
  type: 'user';
  content: string;
  timestamp: number;
}

export interface NormalizedAssistantMessage {
  id: string;
  type: 'assistant';
  textContent: string;
  thinkingContent: string;
  toolCalls: Array<{
    id: string;
    name: string;
    arguments: Record<string, unknown>;
  }>;
  provider: string;
  model: string;
  usage?: {
    inputTokens?: number;
    outputTokens?: number;
    cacheReadTokens?: number;
    cacheWriteTokens?: number;
    totalTokens?: number;
    totalCost?: number;
  };
  stopReason: string | null;
  error: string | null;
  timestamp: number;
  isStreaming: boolean;
}

/** Image data extracted from content blocks */
export interface NormalizedImage {
  data: string;     // Base64 encoded image data
  mimeType: string; // e.g., 'image/png', 'image/jpeg'
}

export interface NormalizedToolResultMessage {
  id: string;
  type: 'tool_result';
  toolCallId: string;
  toolName: string;
  content: string;
  /** Images from tool result content blocks */
  images: NormalizedImage[];
  isError: boolean;
  timestamp: number;
}

export type NormalizedMessage =
  | NormalizedUserMessage
  | NormalizedAssistantMessage
  | NormalizedToolResultMessage;

// ============================================================================
// State Store
// ============================================================================

export type StateListener = (state: AppState, prevState: AppState) => void;

export interface StateStoreOptions {
  cwd?: string;
}

export class StateStore {
  private state: AppState;
  private listeners: Set<StateListener> = new Set();
  private messageIdCounter = 0;

  constructor(options: StateStoreOptions = {}) {
    this.state = this.createInitialState(options.cwd);
  }

  private createInitialState(initialCwd?: string): AppState {
    return {
      ready: false,
      ui: false,
      debug: false,
      status: new Map(),
      title: 'Lemon',
      pendingUIRequests: [],
      error: null,

      // Multi-session state
      primarySessionId: null,
      activeSessionId: null,
      sessions: new Map(),
      runningSessions: [],

      // Active session convenience accessors (defaults for before ready)
      cwd: initialCwd || process.cwd(),
      model: { provider: '', id: '' },
      messages: [],
      streamingMessage: null,
      toolExecutions: new Map(),
      busy: false,
      stats: null,
      cumulativeUsage: {
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        totalCost: 0,
      },
      toolWorkingMessage: null,
      agentWorkingMessage: null,
      widgets: new Map(),
    };
  }

  /**
   * Creates initial session state for a new session.
   */
  private createSessionState(
    sessionId: string,
    cwd: string,
    model: { provider: string; id: string }
  ): SessionState {
    return {
      sessionId,
      cwd,
      model,
      messages: [],
      streamingMessage: null,
      toolExecutions: new Map(),
      busy: false,
      stats: null,
      cumulativeUsage: {
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        totalCost: 0,
      },
      toolWorkingMessage: null,
      agentWorkingMessage: null,
      widgets: new Map(),
      isStreaming: false,
    };
  }

  /**
   * Gets session state by ID, or creates a new one if it doesn't exist.
   */
  private getOrCreateSession(
    sessionId: string,
    cwd?: string,
    model?: { provider: string; id: string }
  ): SessionState {
    let session = this.state.sessions.get(sessionId);
    if (!session) {
      session = this.createSessionState(
        sessionId,
        cwd || this.state.cwd || process.cwd(),
        model || this.state.model || { provider: '', id: '' }
      );
      const sessions = new Map(this.state.sessions);
      sessions.set(sessionId, session);
      this.setState({ sessions });
    }
    return session;
  }

  /**
   * Updates a specific session's state.
   */
  private updateSession(sessionId: string, updates: Partial<SessionState>): void {
    const session = this.state.sessions.get(sessionId);
    if (!session) return;

    const updatedSession = { ...session, ...updates };
    const sessions = new Map(this.state.sessions);
    sessions.set(sessionId, updatedSession);

    // If this is the active session, also update convenience accessors
    const appUpdates: Partial<AppState> = { sessions };
    if (sessionId === this.state.activeSessionId) {
      appUpdates.cwd = updatedSession.cwd;
      appUpdates.model = updatedSession.model;
      appUpdates.messages = updatedSession.messages;
      appUpdates.streamingMessage = updatedSession.streamingMessage;
      appUpdates.toolExecutions = updatedSession.toolExecutions;
      appUpdates.busy = updatedSession.busy;
      appUpdates.stats = updatedSession.stats;
      appUpdates.cumulativeUsage = updatedSession.cumulativeUsage;
      appUpdates.toolWorkingMessage = updatedSession.toolWorkingMessage;
      appUpdates.agentWorkingMessage = updatedSession.agentWorkingMessage;
      appUpdates.widgets = updatedSession.widgets;
    }

    this.setState(appUpdates);
  }

  /**
   * Syncs convenience accessors from the active session.
   */
  private syncFromActiveSession(): void {
    const session = this.state.activeSessionId
      ? this.state.sessions.get(this.state.activeSessionId)
      : null;

    if (session) {
      this.setState({
        cwd: session.cwd,
        model: session.model,
        messages: session.messages,
        streamingMessage: session.streamingMessage,
        toolExecutions: session.toolExecutions,
        busy: session.busy,
        stats: session.stats,
        cumulativeUsage: session.cumulativeUsage,
        toolWorkingMessage: session.toolWorkingMessage,
        agentWorkingMessage: session.agentWorkingMessage,
        widgets: session.widgets,
      });
    }
  }

  /**
   * Gets the session ID to use for operations.
   * If sessionId is provided, use it. Otherwise, use activeSessionId.
   */
  private resolveSessionId(sessionId?: string): string | null {
    return sessionId || this.state.activeSessionId;
  }

  getState(): AppState {
    return this.state;
  }

  subscribe(listener: StateListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private setState(updates: Partial<AppState>): void {
    const prevState = this.state;
    this.state = { ...this.state, ...updates };

    for (const listener of this.listeners) {
      try {
        listener(this.state, prevState);
      } catch (err) {
        console.error('State listener error:', err);
      }
    }
  }

  // ============================================================================
  // Actions
  // ============================================================================

  setReady(
    cwd: string,
    model: { provider: string; id: string },
    ui: boolean,
    debug: boolean,
    primarySessionId?: string | null,
    activeSessionId?: string | null
  ): void {
    const resolvedPrimary = primarySessionId || null;
    const resolvedActive = activeSessionId || null;
    const sessions = new Map<string, SessionState>();

    if (resolvedPrimary) {
      const session = this.createSessionState(resolvedPrimary, cwd, model);
      sessions.set(resolvedPrimary, session);
    } else if (resolvedActive) {
      const session = this.createSessionState(resolvedActive, cwd, model);
      sessions.set(resolvedActive, session);
    }

    const activeSession = resolvedActive ? sessions.get(resolvedActive) : null;

    this.setState({
      ready: true,
      ui,
      debug,
      title: `Lemon - ${model.id}`,
      primarySessionId: resolvedPrimary,
      activeSessionId: resolvedActive,
      sessions,
      // Defaults for when there is no active session
      cwd: activeSession?.cwd || cwd,
      model: activeSession?.model || model,
      messages: activeSession?.messages || [],
      streamingMessage: activeSession?.streamingMessage || null,
      toolExecutions: activeSession?.toolExecutions || new Map(),
      busy: activeSession?.busy || false,
      stats: activeSession?.stats || null,
      cumulativeUsage: activeSession?.cumulativeUsage || {
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        totalCost: 0,
      },
      toolWorkingMessage: activeSession?.toolWorkingMessage || null,
      agentWorkingMessage: activeSession?.agentWorkingMessage || null,
      widgets: activeSession?.widgets || new Map(),
    });
  }

  /**
   * Handles a session_started message from the server.
   */
  handleSessionStarted(
    sessionId: string,
    cwd: string,
    model: { provider: string; id: string }
  ): void {
    const session = this.createSessionState(sessionId, cwd, model);
    const sessions = new Map(this.state.sessions);
    sessions.set(sessionId, session);
    this.setState({ sessions });
  }

  /**
   * Handles a session_closed message from the server.
   */
  handleSessionClosed(sessionId: string, reason: string): void {
    const sessions = new Map(this.state.sessions);
    sessions.delete(sessionId);

    // Update running sessions list
    const runningSessions = this.state.runningSessions.filter(
      (s) => s.sessionId !== sessionId
    );

    const updates: Partial<AppState> = { sessions, runningSessions };

    // If the closed session was active, clear active session (client controls switching)
    if (sessionId === this.state.activeSessionId) {
      updates.activeSessionId = null;
      updates.messages = [];
      updates.streamingMessage = null;
      updates.toolExecutions = new Map();
      updates.busy = false;
      updates.stats = null;
      updates.cumulativeUsage = {
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        totalCost: 0,
      };
      updates.toolWorkingMessage = null;
      updates.agentWorkingMessage = null;
      updates.widgets = new Map();
    }

    this.setState(updates);
  }

  /**
   * Sets the active session and syncs convenience accessors.
   */
  setActiveSessionId(sessionId: string | null): void {
    if (!sessionId) {
      const fallbackCwd = this.state.cwd || process.cwd();
      const fallbackModel = this.state.model || { provider: '', id: '' };
      this.setState({
        activeSessionId: null,
        cwd: fallbackCwd,
        model: fallbackModel,
        messages: [],
        streamingMessage: null,
        toolExecutions: new Map(),
        busy: false,
        stats: null,
        cumulativeUsage: {
          inputTokens: 0,
          outputTokens: 0,
          cacheReadTokens: 0,
          cacheWriteTokens: 0,
          totalCost: 0,
        },
        toolWorkingMessage: null,
        agentWorkingMessage: null,
        widgets: new Map(),
      });
      return;
    }

    // If session doesn't exist yet (race condition with session_started), create it
    // This can happen when active_session message arrives before session_started
    if (!this.state.sessions.has(sessionId)) {
      this.getOrCreateSession(sessionId);
    }

    this.setState({ activeSessionId: sessionId });
    this.syncFromActiveSession();
  }

  /**
   * Updates the list of running sessions from server.
   */
  setRunningSessions(sessions: RunningSessionInfo[]): void {
    const runningSessions: RunningSession[] = sessions.map((s) => ({
      sessionId: s.session_id,
      cwd: s.cwd,
      isStreaming: s.is_streaming,
    }));
    this.setState({ runningSessions });
  }

  /**
   * Gets all running session IDs.
   */
  getSessionIds(): string[] {
    return Array.from(this.state.sessions.keys());
  }

  /**
   * Gets session state by ID.
   */
  getSession(sessionId: string): SessionState | undefined {
    return this.state.sessions.get(sessionId);
  }

  setStats(stats: SessionStats, sessionId?: string): void {
    const targetId = this.resolveSessionId(sessionId);
    if (targetId) {
      this.updateSession(targetId, { stats });
    } else if (!sessionId) {
      // Backward compatibility when no session is specified
      this.setState({ stats });
    }
  }

  setError(message: string | null): void {
    this.setState({ error: message });
  }

  /** Set the agent working message (from ui_working signal) */
  setAgentWorkingMessage(message: string | null, sessionId?: string): void {
    const targetId = this.resolveSessionId(sessionId);
    if (targetId) {
      this.updateSession(targetId, { agentWorkingMessage: message });
    } else if (!sessionId) {
      this.setState({ agentWorkingMessage: message });
    }
  }

  /** Set the tool working message (from tool lifecycle events) */
  setToolWorkingMessage(message: string | null, sessionId?: string): void {
    const targetId = this.resolveSessionId(sessionId);
    if (targetId) {
      this.updateSession(targetId, { toolWorkingMessage: message });
    } else if (!sessionId) {
      this.setState({ toolWorkingMessage: message });
    }
  }

  /** Get the effective working message (agent takes priority over tool) */
  getWorkingMessage(): string | null {
    return this.state.agentWorkingMessage || this.state.toolWorkingMessage;
  }

  /** Legacy setter for backwards compatibility */
  setWorkingMessage(message: string | null): void {
    this.setState({ agentWorkingMessage: message });
  }

  setStatus(key: string, value: string | null): void {
    const status = new Map(this.state.status);
    if (value === null) {
      status.delete(key);
    } else {
      status.set(key, value);
    }
    this.setState({ status });
  }

  setDebug(enabled: boolean): void {
    this.setState({ debug: enabled });
  }

  setTitle(title: string): void {
    this.setState({ title });
  }

  /** Add a UI request to the queue */
  enqueueUIRequest(request: UIRequestMessage): void {
    this.setState({
      pendingUIRequests: [...this.state.pendingUIRequests, request],
    });
  }

  /** Remove and return the first UI request from the queue */
  dequeueUIRequest(): UIRequestMessage | undefined {
    const [first, ...rest] = this.state.pendingUIRequests;
    if (first) {
      this.setState({ pendingUIRequests: rest });
    }
    return first;
  }

  /** Get the current (first) pending UI request without removing it */
  getCurrentUIRequest(): UIRequestMessage | undefined {
    return this.state.pendingUIRequests[0];
  }

  /** Convenience getter for the first pending UI request (alias for getCurrentUIRequest) */
  get pendingUIRequest(): UIRequestMessage | null {
    return this.state.pendingUIRequests[0] || null;
  }

  /** Set or clear the pending UI request (convenience method for single-overlay use) */
  setPendingUIRequest(request: UIRequestMessage | null): void {
    if (request === null) {
      // Clear all pending requests
      this.setState({ pendingUIRequests: [] });
    } else {
      // Replace with single request
      this.setState({ pendingUIRequests: [request] });
    }
  }

  /** Set widget content */
  setWidget(key: string, content: string | string[] | null, opts: Record<string, unknown> = {}, sessionId?: string): void {
    const targetId = this.resolveSessionId(sessionId);

    if (targetId) {
      const session = this.state.sessions.get(targetId);
      if (session) {
        const widgets = new Map(session.widgets);
        if (content === null) {
          widgets.delete(key);
        } else {
          const normalized = Array.isArray(content) ? content : [content];
          widgets.set(key, { content: normalized, opts });
        }
        this.updateSession(targetId, { widgets });
      }
    }

    // Also update global widgets for backward compatibility when no session is specified
    if (!sessionId) {
      const widgets = new Map(this.state.widgets);
      if (content === null) {
        widgets.delete(key);
      } else {
        const normalized = Array.isArray(content) ? content : [content];
        widgets.set(key, { content: normalized, opts });
      }
      this.setState({ widgets });
    }
  }

  // ============================================================================
  // Event Handlers
  // ============================================================================

  /**
   * Handles a session event, routing to the correct session by session_id.
   * @param event The session event
   * @param sessionId Optional session ID (from EventMessage.session_id)
   */
  handleEvent(event: SessionEvent, sessionId?: string): void {
    // Resolve session ID - use provided sessionId, or fall back to active session
    const targetId = this.resolveSessionId(sessionId);

    // Ensure session exists (lazy creation for events from unknown sessions)
    if (targetId && !this.state.sessions.has(targetId)) {
      this.getOrCreateSession(targetId);
    }

    switch (event.type) {
      case 'agent_start':
        this.handleAgentStart(targetId);
        break;

      case 'agent_end':
        this.handleAgentEnd(targetId);
        break;

      case 'turn_start':
        // Nothing specific to do
        break;

      case 'turn_end':
        this.finishStreaming(targetId);
        break;

      case 'message_start': {
        const message = event.data?.[0] as Message | undefined;
        if (message) {
          this.handleMessageStart(message, targetId);
        }
        break;
      }

      case 'message_update': {
        const message = event.data?.[0] as Message | undefined;
        if (message) {
          this.handleMessageUpdate(message, targetId);
        }
        break;
      }

      case 'message_end': {
        const message = event.data?.[0] as Message | undefined;
        if (message) {
          this.handleMessageEnd(message, targetId);
        }
        break;
      }

      case 'tool_execution_start': {
        const [id, name, args] = (event.data ?? []) as [
          string,
          string,
          Record<string, unknown>
        ];
        this.handleToolStart(id, name, args, targetId);
        break;
      }

      case 'tool_execution_update': {
        const [id, name, args, partialResult] = (event.data ?? []) as [
          string,
          string,
          Record<string, unknown>,
          unknown
        ];
        this.handleToolUpdate(id, name, args, partialResult, targetId);
        break;
      }

      case 'tool_execution_end': {
        const [id, name, result, isError] = (event.data ?? []) as [
          string,
          string,
          unknown,
          boolean
        ];
        this.handleToolEnd(id, name, result, isError, targetId);
        break;
      }

      case 'error': {
        const [reason] = (event.data ?? []) as [string];
        this.handleSessionError(reason, targetId);
        break;
      }
    }
  }

  private handleAgentStart(sessionId: string | null): void {
    if (sessionId) {
      this.updateSession(sessionId, { busy: true });
    } else {
      this.setState({ busy: true, error: null });
    }
  }

  private handleAgentEnd(sessionId: string | null): void {
    this.finishStreaming(sessionId);
    if (sessionId) {
      this.updateSession(sessionId, { busy: false });
    } else {
      this.setState({ busy: false });
    }
  }

  private handleSessionError(reason: string, sessionId: string | null): void {
    if (sessionId) {
      this.updateSession(sessionId, { busy: false });
    } else {
      this.setState({ error: reason, busy: false });
    }
  }

  private handleMessageStart(message: Message, sessionId: string | null): void {
    if (message.role === 'assistant') {
      const normalized = this.normalizeAssistantMessage(
        message as AssistantMessage,
        true
      );

      if (sessionId) {
        this.updateSession(sessionId, { streamingMessage: normalized });
      } else {
        this.setState({ streamingMessage: normalized });
      }
    } else if (message.role === 'user') {
      const normalized = this.normalizeUserMessage(message as UserMessage);

      if (sessionId) {
        const session = this.state.sessions.get(sessionId);
        if (session) {
          this.updateSession(sessionId, {
            messages: [...session.messages, normalized],
          });
        }
      } else {
        this.setState({
          messages: [...this.state.messages, normalized],
        });
      }
    }
  }

  private handleMessageUpdate(message: Message, sessionId: string | null): void {
    if (message.role === 'assistant') {
      const normalized = this.normalizeAssistantMessage(
        message as AssistantMessage,
        true
      );

      if (sessionId) {
        this.updateSession(sessionId, { streamingMessage: normalized });
      } else {
        this.setState({ streamingMessage: normalized });
      }
    }
  }

  private handleMessageEnd(message: Message, sessionId: string | null): void {
    if (message.role === 'assistant') {
      const normalized = this.normalizeAssistantMessage(
        message as AssistantMessage,
        false
      );

      if (sessionId) {
        const session = this.state.sessions.get(sessionId);
        if (session) {
          const updatedUsage = this.updateCumulativeUsageForSession(session.cumulativeUsage, normalized);
          this.updateSession(sessionId, {
            messages: [...session.messages, normalized],
            streamingMessage: null,
            cumulativeUsage: updatedUsage,
          });
        }
      } else {
        const updatedUsage = this.updateCumulativeUsage(normalized);
        this.setState({
          messages: [...this.state.messages, normalized],
          streamingMessage: null,
          cumulativeUsage: updatedUsage,
        });
      }
    } else if (message.role === 'tool_result') {
      const normalized = this.normalizeToolResultMessage(
        message as ToolResultMessage
      );

      if (sessionId) {
        const session = this.state.sessions.get(sessionId);
        if (session) {
          this.updateSession(sessionId, {
            messages: [...session.messages, normalized],
          });
        }
      } else {
        this.setState({
          messages: [...this.state.messages, normalized],
        });
      }
    }
  }

  private updateCumulativeUsage(message: NormalizedAssistantMessage): CumulativeUsage {
    return this.updateCumulativeUsageForSession(this.state.cumulativeUsage, message);
  }

  private updateCumulativeUsageForSession(
    current: CumulativeUsage,
    message: NormalizedAssistantMessage
  ): CumulativeUsage {
    const usage = message.usage;

    if (!usage) {
      return current;
    }

    return {
      inputTokens: current.inputTokens + (usage.inputTokens || 0),
      outputTokens: current.outputTokens + (usage.outputTokens || 0),
      cacheReadTokens: current.cacheReadTokens + (usage.cacheReadTokens || 0),
      cacheWriteTokens: current.cacheWriteTokens + (usage.cacheWriteTokens || 0),
      totalCost: current.totalCost + (usage.totalCost || 0),
    };
  }

  private finishStreaming(sessionId: string | null): void {
    // Finish streaming for specific session
    if (sessionId) {
      const session = this.state.sessions.get(sessionId);
      if (session?.streamingMessage) {
        const finalized = {
          ...session.streamingMessage,
          isStreaming: false,
        };
        this.updateSession(sessionId, {
          messages: [...session.messages, finalized],
          streamingMessage: null,
        });
      }
    } else {
      if (this.state.streamingMessage) {
        const finalized = {
          ...this.state.streamingMessage,
          isStreaming: false,
        };
        this.setState({
          messages: [...this.state.messages, finalized],
          streamingMessage: null,
        });
      }
    }
  }

  private handleToolStart(
    id: string,
    name: string,
    args: Record<string, unknown>,
    sessionId: string | null
  ): void {
    const toolExecution: ToolExecution = {
      id,
      name,
      args,
      startTime: Date.now(),
    };

    if (sessionId) {
      const session = this.state.sessions.get(sessionId);
      if (session) {
        const toolExecutions = new Map(session.toolExecutions);
        toolExecutions.set(id, toolExecution);
        this.updateSession(sessionId, {
          toolExecutions,
          toolWorkingMessage: this.deriveToolWorkingMessage(toolExecutions),
        });
      }
    } else {
      const toolExecutions = new Map(this.state.toolExecutions);
      toolExecutions.set(id, toolExecution);
      this.setState({
        toolExecutions,
        toolWorkingMessage: this.deriveToolWorkingMessage(toolExecutions),
      });
    }
  }

  private handleToolUpdate(
    id: string,
    name: string,
    _args: Record<string, unknown>,
    partialResult: unknown,
    sessionId: string | null
  ): void {
    // Extract Task tool specific fields from partial result details
    const taskFields = this.extractTaskFields(name, partialResult);

    if (sessionId) {
      const session = this.state.sessions.get(sessionId);
      if (session) {
        const toolExecutions = new Map(session.toolExecutions);
        const existing = toolExecutions.get(id);
        if (existing) {
          toolExecutions.set(id, { ...existing, partialResult, ...taskFields });
          this.updateSession(sessionId, { toolExecutions });
        }
      }
    } else {
      const toolExecutions = new Map(this.state.toolExecutions);
      const existing = toolExecutions.get(id);
      if (existing) {
        toolExecutions.set(id, { ...existing, partialResult, ...taskFields });
        this.setState({ toolExecutions });
      }
    }
  }

  /**
   * Extract Task tool specific fields from partial result details.
   */
  private extractTaskFields(
    name: string,
    partialResult: unknown
  ): { taskEngine?: string; taskCurrentAction?: { title: string; kind: string; phase: string } } {
    if (name !== 'task' || !partialResult || typeof partialResult !== 'object') {
      return {};
    }

    const result = partialResult as {
      details?: {
        engine?: string;
        current_action?: { title?: string; kind?: string; phase?: string };
        action_detail?: Record<string, unknown>;
      };
    };
    const details = result.details;
    if (!details) {
      return {};
    }

    const fields: { taskEngine?: string; taskCurrentAction?: { title: string; kind: string; phase: string } } = {};

    if (details.engine && typeof details.engine === 'string') {
      fields.taskEngine = details.engine;
    }

    if (details.current_action && typeof details.current_action === 'object') {
      const action = details.current_action;
      if (action.title && action.kind && action.phase) {
        let title = String(action.title);
        const kind = String(action.kind);
        const phase = String(action.phase);

        const detailText = this.extractDetailText(details.action_detail);
        if (detailText) {
          title = `${title}: ${detailText}`;
        }

        fields.taskCurrentAction = { title, kind, phase };
      }
    }

    return fields;
  }

  private extractDetailText(detail: unknown): string | null {
    if (!detail || typeof detail !== 'object') {
      return null;
    }

    const record = detail as Record<string, unknown>;
    const candidates = ['message', 'output', 'stdout', 'stderr', 'result'] as const;

    for (const key of candidates) {
      const value = record[key];
      if (typeof value === 'string' && value.trim() !== '') {
        return value.trim();
      }
    }

    return null;
  }

  private handleToolEnd(
    id: string,
    _name: string,
    result: unknown,
    isError: boolean,
    sessionId: string | null
  ): void {
    if (sessionId) {
      const session = this.state.sessions.get(sessionId);
      if (session) {
        const toolExecutions = new Map(session.toolExecutions);
        const existing = toolExecutions.get(id);
        if (existing) {
          toolExecutions.set(id, {
            ...existing,
            result,
            isError,
            endTime: Date.now(),
          });
        }
        this.updateSession(sessionId, {
          toolExecutions,
          toolWorkingMessage: this.deriveToolWorkingMessage(toolExecutions),
        });
      }
    } else {
      const toolExecutions = new Map(this.state.toolExecutions);
      const existing = toolExecutions.get(id);
      if (existing) {
        toolExecutions.set(id, {
          ...existing,
          result,
          isError,
          endTime: Date.now(),
        });
      }
      this.setState({
        toolExecutions,
        toolWorkingMessage: this.deriveToolWorkingMessage(toolExecutions),
      });
    }
  }

  private deriveToolWorkingMessage(toolExecutions: Map<string, ToolExecution>): string | null {
    const running = Array.from(toolExecutions.values()).filter((tool) => !tool.endTime);

    if (running.length === 0) {
      return null;
    }

    if (running.length === 1) {
      return `Running ${running[0].name}...`;
    }

    return `Running ${running.length} tools...`;
  }

  // ============================================================================
  // Message Normalization
  // ============================================================================

  private normalizeUserMessage(message: UserMessage): NormalizedUserMessage {
    return {
      id: this.generateMessageId(),
      type: 'user',
      content:
        typeof message.content === 'string'
          ? message.content
          : this.extractTextFromContent(message.content as ContentBlock[]),
      timestamp: message.timestamp,
    };
  }

  private normalizeAssistantMessage(
    message: AssistantMessage,
    isStreaming: boolean
  ): NormalizedAssistantMessage {
    const content = message.content || [];
    const textParts: string[] = [];
    const thinkingParts: string[] = [];
    const toolCalls: Array<{
      id: string;
      name: string;
      arguments: Record<string, unknown>;
    }> = [];

    for (const block of content) {
      if (block.type === 'text') {
        textParts.push((block as { text: string }).text || '');
      } else if (block.type === 'thinking') {
        thinkingParts.push((block as { thinking: string }).thinking || '');
      } else if (block.type === 'tool_call') {
        const toolCall = block as {
          id: string;
          name: string;
          arguments: Record<string, unknown>;
        };
        toolCalls.push({
          id: toolCall.id,
          name: toolCall.name,
          arguments: toolCall.arguments || {},
        });
      }
    }

    return {
      id: `assistant_${message.timestamp}`,
      type: 'assistant',
      textContent: textParts.join(''),
      thinkingContent: thinkingParts.join(''),
      toolCalls,
      provider: message.provider,
      model: message.model,
      usage: message.usage
        ? {
            inputTokens: message.usage.input,
            outputTokens: message.usage.output,
            cacheReadTokens: message.usage.cache_read,
            cacheWriteTokens: message.usage.cache_write,
            totalTokens: message.usage.total_tokens,
            totalCost: message.usage.cost?.total,
          }
        : undefined,
      stopReason: message.stop_reason,
      error: message.error_message,
      timestamp: message.timestamp,
      isStreaming,
    };
  }

  private normalizeToolResultMessage(
    message: ToolResultMessage
  ): NormalizedToolResultMessage {
    const { text, images } = this.extractContentWithImages(message.content);
    return {
      id: message.tool_call_id,
      type: 'tool_result',
      toolCallId: message.tool_call_id,
      toolName: message.tool_name,
      content: text,
      images,
      isError: message.is_error,
      timestamp: message.timestamp,
    };
  }

  private extractTextFromContent(content: ContentBlock[]): string {
    if (!content || !Array.isArray(content)) {
      return '';
    }

    return content
      .filter((b) => b.type === 'text')
      .map((b) => (b as { text: string }).text || '')
      .join('');
  }

  private extractContentWithImages(content: ContentBlock[]): { text: string; images: NormalizedImage[] } {
    if (!content || !Array.isArray(content)) {
      return { text: '', images: [] };
    }

    const textParts: string[] = [];
    const images: NormalizedImage[] = [];

    for (const block of content) {
      if (block.type === 'text') {
        textParts.push((block as { text: string }).text || '');
      } else if (block.type === 'image') {
        const imageBlock = block as { data: string; mime_type: string };
        if (imageBlock.data && imageBlock.mime_type) {
          images.push({
            data: imageBlock.data,
            mimeType: imageBlock.mime_type,
          });
        }
      }
    }

    return { text: textParts.join(''), images };
  }

  private generateMessageId(): string {
    return `msg_${++this.messageIdCounter}`;
  }

  // ============================================================================
  // Utilities
  // ============================================================================

  /**
   * Resets the active session's state (keeps session metadata but clears messages).
   */
  resetActiveSession(): void {
    const activeId = this.state.activeSessionId;
    if (!activeId) return;

    const session = this.state.sessions.get(activeId);
    if (!session) return;

    const resetSession: SessionState = {
      ...session,
      messages: [],
      streamingMessage: null,
      toolExecutions: new Map(),
      busy: false,
      stats: null,
      cumulativeUsage: {
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        totalCost: 0,
      },
      toolWorkingMessage: null,
      agentWorkingMessage: null,
      widgets: new Map(),
    };

    const sessions = new Map(this.state.sessions);
    sessions.set(activeId, resetSession);

    this.setState({
      sessions,
      messages: [],
      streamingMessage: null,
      toolExecutions: new Map(),
      busy: false,
      stats: null,
      cumulativeUsage: {
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        totalCost: 0,
      },
      toolWorkingMessage: null,
      agentWorkingMessage: null,
      widgets: new Map(),
      error: null,
    });
  }

  /**
   * Full reset - clears all state including sessions.
   */
  reset(): void {
    this.state = this.createInitialState();
    this.messageIdCounter = 0;
    // Notify listeners of reset
    for (const listener of this.listeners) {
      try {
        listener(this.state, this.state);
      } catch (err) {
        console.error('State listener error:', err);
      }
    }
  }
}
