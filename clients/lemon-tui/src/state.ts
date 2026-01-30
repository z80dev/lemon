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
}

/** Cumulative token and cost tracking */
export interface CumulativeUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  totalCost: number;
}

export interface AppState {
  /** Connection ready state */
  ready: boolean;
  /** Current working directory */
  cwd: string;
  /** Model info */
  model: { provider: string; id: string };
  /** UI support enabled */
  ui: boolean;
  /** Debug mode enabled */
  debug: boolean;
  /** All messages in the conversation */
  messages: NormalizedMessage[];
  /** Currently streaming assistant message (null if not streaming) */
  streamingMessage: NormalizedAssistantMessage | null;
  /** Active tool executions */
  toolExecutions: Map<string, ToolExecution>;
  /** Agent is processing */
  busy: boolean;
  /** Session stats */
  stats: SessionStats | null;
  /** Cumulative token and cost usage */
  cumulativeUsage: CumulativeUsage;
  /** Current status line values */
  status: Map<string, string | null>;
  /** Tool working message (e.g., "Running bash...") - set by tool lifecycle */
  toolWorkingMessage: string | null;
  /** Agent working message (e.g., "Summarizing branch...") - set by ui_working signal */
  agentWorkingMessage: string | null;
  /** Window title */
  title: string;
  /** Pending UI requests queue (overlays) */
  pendingUIRequests: UIRequestMessage[];
  /** Widget content by key */
  widgets: Map<string, { content: string[]; opts: Record<string, unknown> }>;
  /** Error message to display */
  error: string | null;
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

export class StateStore {
  private state: AppState;
  private listeners: Set<StateListener> = new Set();
  private messageIdCounter = 0;

  constructor() {
    this.state = this.createInitialState();
  }

  private createInitialState(): AppState {
    return {
      ready: false,
      cwd: process.cwd(),
      model: { provider: '', id: '' },
      ui: false,
      debug: false,
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
      status: new Map(),
      toolWorkingMessage: null,
      agentWorkingMessage: null,
      title: 'Lemon',
      pendingUIRequests: [],
      widgets: new Map(),
      error: null,
    };
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
    debug: boolean
  ): void {
    this.setState({
      ready: true,
      cwd,
      model,
      ui,
      debug,
      title: `Lemon - ${model.id}`,
    });
  }

  setStats(stats: SessionStats): void {
    this.setState({ stats });
  }

  setError(message: string | null): void {
    this.setState({ error: message });
  }

  /** Set the agent working message (from ui_working signal) */
  setAgentWorkingMessage(message: string | null): void {
    this.setState({ agentWorkingMessage: message });
  }

  /** Set the tool working message (from tool lifecycle events) */
  setToolWorkingMessage(message: string | null): void {
    this.setState({ toolWorkingMessage: message });
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
  setWidget(key: string, content: string | string[] | null, opts: Record<string, unknown> = {}): void {
    const widgets = new Map(this.state.widgets);
    if (content === null) {
      widgets.delete(key);
    } else {
      const normalized = Array.isArray(content) ? content : [content];
      widgets.set(key, { content: normalized, opts });
    }
    this.setState({ widgets });
  }

  // ============================================================================
  // Event Handlers
  // ============================================================================

  handleEvent(event: SessionEvent): void {
    switch (event.type) {
      case 'agent_start':
        this.setState({ busy: true, error: null });
        break;

      case 'agent_end':
        this.finishStreaming();
        this.setState({ busy: false });
        break;

      case 'turn_start':
        // Nothing specific to do
        break;

      case 'turn_end':
        this.finishStreaming();
        break;

      case 'message_start': {
        const message = event.data?.[0] as Message | undefined;
        if (message) {
          this.handleMessageStart(message);
        }
        break;
      }

      case 'message_update': {
        const message = event.data?.[0] as Message | undefined;
        if (message) {
          this.handleMessageUpdate(message);
        }
        break;
      }

      case 'message_end': {
        const message = event.data?.[0] as Message | undefined;
        if (message) {
          this.handleMessageEnd(message);
        }
        break;
      }

      case 'tool_execution_start': {
        const [id, name, args] = (event.data ?? []) as [
          string,
          string,
          Record<string, unknown>
        ];
        this.handleToolStart(id, name, args);
        break;
      }

      case 'tool_execution_update': {
        const [id, name, args, partialResult] = (event.data ?? []) as [
          string,
          string,
          Record<string, unknown>,
          unknown
        ];
        this.handleToolUpdate(id, name, args, partialResult);
        break;
      }

      case 'tool_execution_end': {
        const [id, name, result, isError] = (event.data ?? []) as [
          string,
          string,
          unknown,
          boolean
        ];
        this.handleToolEnd(id, name, result, isError);
        break;
      }

      case 'error': {
        const [reason] = (event.data ?? []) as [string];
        this.setState({ error: reason, busy: false });
        break;
      }
    }
  }

  private handleMessageStart(message: Message): void {
    if (message.role === 'assistant') {
      const normalized = this.normalizeAssistantMessage(
        message as AssistantMessage,
        true
      );
      this.setState({ streamingMessage: normalized });
    } else if (message.role === 'user') {
      const normalized = this.normalizeUserMessage(message as UserMessage);
      this.setState({
        messages: [...this.state.messages, normalized],
      });
    }
  }

  private handleMessageUpdate(message: Message): void {
    if (message.role === 'assistant') {
      const normalized = this.normalizeAssistantMessage(
        message as AssistantMessage,
        true
      );
      this.setState({ streamingMessage: normalized });
    }
  }

  private handleMessageEnd(message: Message): void {
    if (message.role === 'assistant') {
      const normalized = this.normalizeAssistantMessage(
        message as AssistantMessage,
        false
      );
      // Update cumulative usage
      const updatedUsage = this.updateCumulativeUsage(normalized);
      this.setState({
        messages: [...this.state.messages, normalized],
        streamingMessage: null,
        cumulativeUsage: updatedUsage,
      });
    } else if (message.role === 'tool_result') {
      const normalized = this.normalizeToolResultMessage(
        message as ToolResultMessage
      );
      this.setState({
        messages: [...this.state.messages, normalized],
      });
    }
  }

  private updateCumulativeUsage(message: NormalizedAssistantMessage): CumulativeUsage {
    const current = this.state.cumulativeUsage;
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

  private finishStreaming(): void {
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

  private handleToolStart(
    id: string,
    name: string,
    args: Record<string, unknown>
  ): void {
    const toolExecutions = new Map(this.state.toolExecutions);
    toolExecutions.set(id, {
      id,
      name,
      args,
      startTime: Date.now(),
    });
    this.setState({
      toolExecutions,
      toolWorkingMessage: `Running ${name}...`,
    });
  }

  private handleToolUpdate(
    id: string,
    _name: string,
    _args: Record<string, unknown>,
    partialResult: unknown
  ): void {
    const toolExecutions = new Map(this.state.toolExecutions);
    const existing = toolExecutions.get(id);
    if (existing) {
      toolExecutions.set(id, { ...existing, partialResult });
      this.setState({ toolExecutions });
    }
  }

  private handleToolEnd(
    id: string,
    _name: string,
    result: unknown,
    isError: boolean
  ): void {
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
      toolWorkingMessage: null,
    });
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
