#!/usr/bin/env node
/**
 * Lemon TUI - Terminal User Interface for the Lemon coding agent.
 */

import {
  TUI,
  ProcessTerminal,
  Text,
  Editor,
  Input,
  Markdown,
  Loader,
  Container,
  SelectList,
  matchesKey,
  type EditorTheme,
  type MarkdownTheme,
  type SelectListTheme,
  type Component,
  type SelectItem,
} from '@mariozechner/pi-tui';
import { AgentConnection, type AgentConnectionOptions } from './agent-connection.js';
import { StateStore, type AppState, type NormalizedMessage, type NormalizedAssistantMessage } from './state.js';
import type { ServerMessage, UIRequestMessage, SelectParams, ConfirmParams, InputParams, EditorParams } from './types.js';

// ============================================================================
// Theme
// ============================================================================

const ansi = {
  primary: (s: string) => `\x1b[38;5;220m${s}\x1b[0m`,    // Lemon yellow
  secondary: (s: string) => `\x1b[38;5;228m${s}\x1b[0m`,  // Pale lemon
  success: (s: string) => `\x1b[38;5;114m${s}\x1b[0m`,    // Citrus green
  warning: (s: string) => `\x1b[38;5;214m${s}\x1b[0m`,    // Orange
  error: (s: string) => `\x1b[38;5;203m${s}\x1b[0m`,      // Red
  muted: (s: string) => `\x1b[38;5;243m${s}\x1b[0m`,      // Gray
  dim: (s: string) => `\x1b[2m${s}\x1b[0m`,
  bold: (s: string) => `\x1b[1m${s}\x1b[0m`,
  italic: (s: string) => `\x1b[3m${s}\x1b[0m`,
};

const selectListTheme: SelectListTheme = {
  selectedPrefix: ansi.primary,
  selectedText: ansi.bold,
  description: ansi.muted,
  scrollInfo: ansi.muted,
  noMatch: ansi.muted,
};

const markdownTheme: MarkdownTheme = {
  heading: (s: string) => ansi.bold(ansi.primary(s)),
  link: ansi.primary,
  linkUrl: ansi.muted,
  code: ansi.warning,
  codeBlock: ansi.success,
  codeBlockBorder: ansi.muted,
  quote: ansi.italic,
  quoteBorder: ansi.muted,
  hr: ansi.muted,
  listBullet: ansi.primary,
  bold: ansi.bold,
  italic: ansi.italic,
  strikethrough: (s: string) => `\x1b[9m${s}\x1b[0m`,
  underline: (s: string) => `\x1b[4m${s}\x1b[0m`,
};

const editorTheme: EditorTheme = {
  borderColor: ansi.primary,
  selectList: selectListTheme,
};

// ============================================================================
// Main Application
// ============================================================================

class LemonTUI {
  private tui: TUI;
  private connection: AgentConnection;
  private store: StateStore;

  private header: Text;
  private messagesContainer: Container;
  private widgetsContainer: Container;
  private toolPanel: Container;
  private toolExecutionBar: Text;
  private statusBar: Text;
  private inputEditor: Editor;
  private loader: Loader | null = null;

  private overlayHandle: { hide: () => void } | null = null;
  private streamingComponent: Component | null = null;
  private currentOverlayRequestId: string | null = null;

  constructor(options: AgentConnectionOptions = {}) {
    this.tui = new TUI(new ProcessTerminal());
    this.connection = new AgentConnection(options);
    this.store = new StateStore();

    // Initialize components
    this.header = new Text('', 1, 0);
    this.widgetsContainer = new Container();
    this.messagesContainer = new Container();
    this.toolPanel = new Container();
    this.toolExecutionBar = new Text('', 1, 0);
    this.statusBar = new Text('', 1, 0);
    this.inputEditor = new Editor(this.tui, editorTheme);

    this.setupUI();
    this.setupEventHandlers();
  }

  private setupUI(): void {
    // Update header
    this.updateHeader();

    // Add components to TUI
    // Tool panel and execution bar appear above messages so assistant response is always last
    this.tui.addChild(this.header);
    this.tui.addChild(this.widgetsContainer);
    this.tui.addChild(this.toolPanel);
    this.tui.addChild(this.toolExecutionBar);
    this.tui.addChild(this.messagesContainer);
    this.tui.addChild(this.statusBar);
    this.tui.addChild(this.inputEditor);

    // Focus the editor
    this.tui.setFocus(this.inputEditor);

    // Handle editor submit
    this.inputEditor.onSubmit = (text: string) => {
      if (this.store.getState().busy) {
        // Ignore input while agent is processing
        return;
      }
      this.handleInput(text);
      this.inputEditor.setText('');
    };

    // Subscribe to state changes
    this.store.subscribe((state, prevState) => {
      this.onStateChange(state, prevState);
    });
  }

  private setupEventHandlers(): void {
    // Connection events
    this.connection.on('ready', (msg) => {
      this.store.setReady(msg.cwd, msg.model, msg.ui, msg.debug);
    });

    this.connection.on('message', (msg) => {
      this.handleServerMessage(msg);
    });

    this.connection.on('error', (err) => {
      this.store.setError(err.message);
    });

    this.connection.on('close', (code) => {
      this.store.setError(`Connection closed (code: ${code})`);
    });

    // Handle Ctrl+C
    process.on('SIGINT', () => {
      if (this.store.getState().busy) {
        this.connection.abort();
      } else {
        this.stop();
      }
    });
  }

  private handleServerMessage(msg: ServerMessage): void {
    switch (msg.type) {
      case 'event':
        this.store.handleEvent(msg.event);
        break;

      case 'stats':
        this.store.setStats(msg.stats);
        break;

      case 'error':
        this.store.setError(msg.message);
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
    }
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

    // Send as prompt
    this.connection.prompt(trimmed);
  }

  private handleCommand(cmd: string, _args: string[]): void {
    switch (cmd.toLowerCase()) {
      case 'abort':
        this.connection.abort();
        break;

      case 'reset':
        this.connection.reset();
        this.store.reset();
        this.clearMessages();
        break;

      case 'save':
        this.connection.save();
        break;

      case 'stats':
        this.connection.stats();
        break;

      case 'quit':
      case 'exit':
      case 'q':
        this.stop();
        break;

      case 'help':
        this.showHelp();
        break;

      default:
        this.store.setError(`Unknown command: /${cmd}`);
    }
  }

  private showHelp(): void {
    const helpText = `${ansi.bold('Commands:')}
  /abort  - Stop the current operation
  /reset  - Clear conversation and reset session
  /save   - Save the current session
  /stats  - Show session statistics
  /quit   - Exit the application
  /help   - Show this help message

${ansi.bold('Shortcuts:')}
  Enter         - Send message
  Shift+Enter   - New line in editor
  Ctrl+C        - Abort (if running) or quit
  Escape        - Cancel overlay dialogs`;

    this.messagesContainer.addChild(new Text(helpText, 1, 1));
    this.tui.requestRender();
  }

  private clearMessages(): void {
    this.messagesContainer.clear();
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
      if (value) {
        parts.push(ansi.secondary(`${key}: ${value}`));
      }
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

  private updateToolExecutionBar(): void {
    const state = this.store.getState();
    const activeTools: string[] = [];

    for (const [, tool] of state.toolExecutions) {
      if (!tool.endTime) {
        // Tool is still running
        const elapsed = Math.floor((Date.now() - tool.startTime) / 1000);
        activeTools.push(`${ansi.warning('▶')} ${tool.name} (${elapsed}s)`);
      }
    }

    if (activeTools.length > 0) {
      this.toolExecutionBar.setText(activeTools.join(' | '));
    } else {
      this.toolExecutionBar.setText('');
    }
  }

  private updateToolPanel(): void {
    const state = this.store.getState();
    const tools = Array.from(state.toolExecutions.values());

    this.toolPanel.clear();

    if (tools.length === 0) {
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

      const argsText = this.formatToolArgs(tool.args);
      if (argsText) {
        this.toolPanel.addChild(new Text(ansi.muted(`  args: ${argsText}`), 1, 0));
      }

      const resultPayload = tool.result ?? tool.partialResult;
      if (resultPayload !== undefined) {
        const label = tool.result ? '  result:' : '  partial:';
        const resultText = this.formatToolResult(resultPayload);
        if (resultText) {
          this.toolPanel.addChild(new Text(ansi.secondary(`${label} ${resultText}`), 1, 0));
        }
      }

      this.toolPanel.addChild(new Text('', 1, 0));
    }
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

  private onStateChange(state: AppState, prevState: AppState): void {
    // Update header
    if (state.ready !== prevState.ready || state.model !== prevState.model) {
      this.updateHeader();
    }

    // Update status bar
    this.updateStatusBar();

    // Update tool execution bar
    if (state.toolExecutions !== prevState.toolExecutions) {
      this.updateToolExecutionBar();
      this.updateToolPanel();
    }

    // Update widgets
    if (state.widgets !== prevState.widgets) {
      this.updateWidgets();
    }

    // Update messages
    if (state.messages.length !== prevState.messages.length) {
      // Add new messages
      for (let i = prevState.messages.length; i < state.messages.length; i++) {
        const msg = state.messages[i];
        const component = this.createMessageComponent(msg);
        this.messagesContainer.addChild(component);
      }
    }

    // Update streaming message
    if (state.streamingMessage !== prevState.streamingMessage) {
      this.updateStreamingMessage(state.streamingMessage);
    }

    // Update loader
    if (state.busy !== prevState.busy) {
      this.updateLoader(state.busy);
    }

    // Update terminal title using pi-tui's terminal interface
    if (state.title !== prevState.title) {
      this.tui.terminal.setTitle(state.title);
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

  private createMessageComponent(message: NormalizedMessage): Component {
    switch (message.type) {
      case 'user':
        return new Markdown(`${ansi.primary(ansi.bold('You:'))}\n${message.content}`, 1, 1, markdownTheme);

      case 'assistant': {
        const assistant = message as NormalizedAssistantMessage;
        const lines: string[] = [];

        lines.push(ansi.success(ansi.bold('Assistant:')));

        // Thinking (if any, shown dimmed)
        if (assistant.thinkingContent) {
          lines.push(ansi.dim(ansi.italic('[thinking]')));
          lines.push(ansi.muted(assistant.thinkingContent.slice(0, 200) + '...'));
          lines.push('');
        }

        // Main content
        if (assistant.textContent) {
          lines.push(assistant.textContent);
        }

        // Tool calls
        for (const tool of assistant.toolCalls) {
          lines.push(`${ansi.warning('→')} ${tool.name}`);
        }

        // Streaming indicator
        if (assistant.isStreaming) {
          lines.push(ansi.muted('...'));
        }

        return new Markdown(lines.join('\n'), 1, 1, markdownTheme);
      }

      case 'tool_result': {
        const colorFn = message.isError ? ansi.error : ansi.secondary;
        const content = message.content.length > 500
          ? message.content.slice(0, 500) + '...'
          : message.content;
        return new Text(colorFn(`[${message.toolName}] ${content}`), 1, 1);
      }
    }
  }

  private updateStreamingMessage(message: NormalizedAssistantMessage | null): void {
    if (message) {
      if (this.streamingComponent) {
        this.messagesContainer.removeChild(this.streamingComponent);
      }
      this.streamingComponent = this.createMessageComponent(message);
      this.messagesContainer.addChild(this.streamingComponent);
    } else {
      if (this.streamingComponent) {
        this.messagesContainer.removeChild(this.streamingComponent);
        this.streamingComponent = null;
      }
    }
  }

  private formatToolArgs(args: Record<string, unknown>): string {
    if (!args || Object.keys(args).length === 0) {
      return '';
    }
    const json = this.safeStringify(args);
    return this.truncateInline(json, 200);
  }

  private formatToolResult(result: unknown): string {
    const text = this.extractToolText(result);
    if (text) {
      return this.truncateMultiline(text, 6, 600);
    }
    const json = this.safeStringify(result);
    return this.truncateMultiline(json, 6, 600);
  }

  private extractToolText(result: unknown): string {
    if (result === null || result === undefined) {
      return '';
    }
    if (typeof result === 'string') {
      return result;
    }
    if (typeof result === 'number' || typeof result === 'boolean') {
      return String(result);
    }
    if (Array.isArray(result)) {
      return this.extractTextFromContentBlocks(result);
    }
    if (typeof result === 'object') {
      const record = result as { content?: unknown; details?: unknown };
      const contentText = this.extractTextFromContentBlocks(record.content);
      if (contentText) {
        return contentText;
      }
      if (record.details !== undefined) {
        const detailsText = this.safeStringify(record.details);
        return detailsText ? `details: ${detailsText}` : '';
      }
    }
    return '';
  }

  private extractTextFromContentBlocks(content: unknown): string {
    if (!Array.isArray(content)) {
      return '';
    }
    const parts: string[] = [];
    let imageCount = 0;
    for (const block of content) {
      if (!block || typeof block !== 'object') {
        continue;
      }
      const type = (block as { type?: string }).type;
      if (type === 'text') {
        const text = (block as { text?: string }).text ?? '';
        if (text) parts.push(text);
      } else if (type === 'image') {
        imageCount += 1;
      }
    }
    if (imageCount > 0) {
      parts.push(`[${imageCount} image${imageCount === 1 ? '' : 's'}]`);
    }
    return parts.join('');
  }

  private safeStringify(value: unknown): string {
    try {
      const seen = new WeakSet();
      return JSON.stringify(
        value,
        (_key, val) => {
          if (typeof val === 'object' && val !== null) {
            if (seen.has(val)) {
              return '[Circular]';
            }
            seen.add(val);
          }
          return val;
        },
        0
      );
    } catch {
      try {
        return String(value);
      } catch {
        return '[unserializable]';
      }
    }
  }

  private truncateInline(text: string, maxChars: number): string {
    if (text.length <= maxChars) {
      return text;
    }
    return `${text.slice(0, maxChars)}...`;
  }

  private truncateMultiline(text: string, maxLines: number, maxChars: number): string {
    const normalized = text.length > maxChars ? `${text.slice(0, maxChars)}...` : text;
    const lines = normalized.split(/\r?\n/);
    if (lines.length <= maxLines) {
      return normalized;
    }
    const remaining = lines.length - maxLines;
    return `${lines.slice(0, maxLines).join('\n')}\n... (${remaining} more lines)`;
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
    this.currentOverlayRequestId = request.id;

    switch (request.method) {
      case 'select':
        this.showSelectOverlay(request.id, request.params as SelectParams);
        break;

      case 'confirm':
        this.showConfirmOverlay(request.id, request.params as ConfirmParams);
        break;

      case 'input':
        this.showInputOverlay(request.id, request.params as InputParams);
        break;

      case 'editor':
        this.showEditorOverlay(request.id, request.params as EditorParams);
        break;
    }
  }

  private showSelectOverlay(id: string, params: SelectParams): void {
    const items: SelectItem[] = params.options.map((opt) => ({
      label: opt.label,
      value: opt.value,
      description: opt.description || undefined,
    }));

    const titleText = new Text(ansi.bold(params.title), 1, 0);
    const selectList = new SelectList(items, Math.min(10, items.length), selectListTheme);

    selectList.onSelect = (item: SelectItem) => {
      this.connection.respondToUIRequest(id, item.value);
      this.hideOverlay();
    };

    selectList.onCancel = () => {
      this.connection.respondToUIRequest(id, null);
      this.hideOverlay();
    };

    const container = new Container();
    container.addChild(titleText);
    container.addChild(selectList);

    this.overlayHandle = this.tui.showOverlay(container, {
      width: '80%',
      maxHeight: '50%',
      anchor: 'center',
    });
    this.tui.setFocus(selectList);
  }

  private showConfirmOverlay(id: string, params: ConfirmParams): void {
    const items: SelectItem[] = [
      { label: 'Yes', value: 'yes', description: 'Confirm' },
      { label: 'No', value: 'no', description: 'Cancel' },
    ];

    const header = new Text(`${ansi.bold(params.title)}\n${params.message}`, 1, 1);
    const selectList = new SelectList(items, 2, selectListTheme);

    selectList.onSelect = (item: SelectItem) => {
      this.connection.respondToUIRequest(id, item.value === 'yes');
      this.hideOverlay();
    };

    selectList.onCancel = () => {
      this.connection.respondToUIRequest(id, false);
      this.hideOverlay();
    };

    const container = new Container();
    container.addChild(header);
    container.addChild(selectList);

    this.overlayHandle = this.tui.showOverlay(container, {
      width: 60,
      anchor: 'center',
    });
    this.tui.setFocus(selectList);
  }

  private showInputOverlay(id: string, params: InputParams): void {
    const header = new Text(ansi.bold(params.title), 1, 0);
    const input = new Input();

    // Note: pi-tui Input doesn't support placeholder, but we show it in the header
    if (params.placeholder) {
      header.setText(`${ansi.bold(params.title)}\n${ansi.muted(params.placeholder)}`);
    }

    input.onSubmit = (text: string) => {
      this.connection.respondToUIRequest(id, text);
      this.hideOverlay();
    };

    input.onEscape = () => {
      this.connection.respondToUIRequest(id, null);
      this.hideOverlay();
    };

    const container = new Container();
    container.addChild(header);
    container.addChild(input);

    this.overlayHandle = this.tui.showOverlay(container, {
      width: '80%',
      anchor: 'center',
    });
    this.tui.setFocus(input);
  }

  private showEditorOverlay(id: string, params: EditorParams): void {
    const header = new Text(
      `${ansi.bold(params.title)}\n${ansi.muted('Enter to submit, Shift+Enter for newline, Escape to cancel')}`,
      1,
      0
    );
    const editorOverlay = new Editor(this.tui, editorTheme);

    if (params.prefill) {
      editorOverlay.setText(params.prefill);
    }

    editorOverlay.onSubmit = (text: string) => {
      this.connection.respondToUIRequest(id, text);
      this.hideOverlay();
    };

    // Store original handleInput for escape handling using matchesKey
    const originalHandleInput = editorOverlay.handleInput?.bind(editorOverlay);
    editorOverlay.handleInput = (data: string) => {
      if (matchesKey(data, 'escape')) {
        this.connection.respondToUIRequest(id, null);
        this.hideOverlay();
        return;
      }
      originalHandleInput?.(data);
    };

    const container = new Container();
    container.addChild(header);
    container.addChild(editorOverlay);

    this.overlayHandle = this.tui.showOverlay(container, {
      width: '90%',
      maxHeight: '80%',
      anchor: 'center',
    });
    this.tui.setFocus(editorOverlay);
  }

  private hideOverlay(): void {
    if (this.overlayHandle) {
      this.overlayHandle.hide();
      this.overlayHandle = null;
    }
    this.currentOverlayRequestId = null;

    // Dequeue the current request
    this.store.dequeueUIRequest();

    // Let onStateChange show the next overlay if any
    if (!this.store.getCurrentUIRequest()) {
      this.tui.setFocus(this.inputEditor);
    }
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
    this.tui.stop();
    this.connection.stop();
    process.exit(0);
  }
}

// ============================================================================
// CLI Entry Point
// ============================================================================

function parseArgs(): AgentConnectionOptions {
  const args = process.argv.slice(2);
  const options: AgentConnectionOptions = {};

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];

    switch (arg) {
      case '--cwd':
      case '-d':
        options.cwd = args[++i];
        break;

      case '--model':
      case '-m':
        options.model = args[++i];
        break;

      case '--base-url':
        options.baseUrl = args[++i];
        break;

      case '--system-prompt':
        options.systemPrompt = args[++i];
        break;

      case '--debug':
        options.debug = true;
        break;

      case '--no-ui':
        options.ui = false;
        break;

      case '--lemon-path':
        options.lemonPath = args[++i];
        break;

      case '--help':
      case '-h':
        console.log(`
Lemon TUI - Terminal interface for Lemon coding agent

Usage: lemon-tui [options]

Options:
  --cwd, -d <path>       Working directory for the agent
  --model, -m <spec>     Model specification (provider:model_id)
  --base-url <url>       Base URL override for model provider
  --system-prompt <text> Custom system prompt
  --debug                Enable debug mode
  --no-ui                Disable UI overlays
  --lemon-path <path>    Path to lemon project root
  --help, -h             Show this help message
`);
        process.exit(0);
        break;

      default:
        if (arg.startsWith('-')) {
          console.error(`Unknown option: ${arg}`);
          process.exit(1);
        }
    }
  }

  return options;
}

// Main
const options = parseArgs();
const app = new LemonTUI(options);
app.start();
