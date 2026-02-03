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
  SettingsList,
  Image,
  matchesKey,
  CombinedAutocompleteProvider,
  visibleWidth,
  type AutocompleteItem,
  type AutocompleteProvider,
  type EditorTheme,
  type MarkdownTheme,
  type SelectListTheme,
  type SettingsListTheme,
  type ImageTheme,
  type SettingItem,
  type Component,
  type SelectItem,
  type SlashCommand,
} from '@mariozechner/pi-tui';
import { execFile } from 'node:child_process';
import { AgentConnection, type AgentConnectionOptions } from './agent-connection.js';
import { parseModelSpec, resolveConfig, saveTUIConfigKey, getModelString, type ResolvedConfig } from './config.js';
import { StateStore, type AppState, type NormalizedMessage, type NormalizedAssistantMessage, type NormalizedToolResultMessage } from './state.js';
import type { ServerMessage, UIRequestMessage, SelectParams, ConfirmParams, InputParams, EditorParams, SessionSummary } from './types.js';

// ============================================================================
// Theme
// ============================================================================

/**
 * Theme interface defining all color functions used throughout the TUI.
 */
interface Theme {
  name: string;
  primary: (s: string) => string;
  secondary: (s: string) => string;
  success: (s: string) => string;
  warning: (s: string) => string;
  error: (s: string) => string;
  muted: (s: string) => string;
  dim: (s: string) => string;
  bold: (s: string) => string;
  italic: (s: string) => string;
  modelineBg: (s: string) => string;
  overlayBg: (s: string) => string;
  border: (s: string) => string;
}

/**
 * The lemon theme - warm yellow tones with citrus accents.
 */
const lemonTheme: Theme = {
  name: 'lemon',
  primary: (s: string) => `\x1b[38;5;220m${s}\x1b[0m`,    // Lemon yellow
  secondary: (s: string) => `\x1b[38;5;228m${s}\x1b[0m`,  // Pale lemon
  success: (s: string) => `\x1b[38;5;114m${s}\x1b[0m`,    // Citrus green
  warning: (s: string) => `\x1b[38;5;214m${s}\x1b[0m`,    // Orange
  error: (s: string) => `\x1b[38;5;203m${s}\x1b[0m`,      // Red
  muted: (s: string) => `\x1b[38;5;243m${s}\x1b[0m`,      // Gray
  dim: (s: string) => `\x1b[2m${s}\x1b[0m`,
  bold: (s: string) => `\x1b[1m${s}\x1b[0m`,
  italic: (s: string) => `\x1b[3m${s}\x1b[0m`,
  modelineBg: (s: string) => `\x1b[48;5;58m${s}\x1b[0m`,  // Dark olive/yellow bg
  overlayBg: (s: string) => `\x1b[48;5;236m${s}\x1b[0m`,  // Dark gray bg for overlays
  border: (s: string) => `\x1b[38;5;243m${s}\x1b[0m`,     // Subtle gray border
};

/**
 * The lime theme - fresh green tones.
 */
const limeTheme: Theme = {
  name: 'lime',
  primary: (s: string) => `\x1b[38;5;118m${s}\x1b[0m`,    // Bright green
  secondary: (s: string) => `\x1b[38;5;157m${s}\x1b[0m`,  // Pale green
  success: (s: string) => `\x1b[38;5;114m${s}\x1b[0m`,    // Citrus green
  warning: (s: string) => `\x1b[38;5;214m${s}\x1b[0m`,    // Orange
  error: (s: string) => `\x1b[38;5;203m${s}\x1b[0m`,      // Red
  muted: (s: string) => `\x1b[38;5;243m${s}\x1b[0m`,      // Gray
  dim: (s: string) => `\x1b[2m${s}\x1b[0m`,
  bold: (s: string) => `\x1b[1m${s}\x1b[0m`,
  italic: (s: string) => `\x1b[3m${s}\x1b[0m`,
  modelineBg: (s: string) => `\x1b[48;5;22m${s}\x1b[0m`,  // Dark green bg
  overlayBg: (s: string) => `\x1b[48;5;236m${s}\x1b[0m`,  // Dark gray bg for overlays
  border: (s: string) => `\x1b[38;5;243m${s}\x1b[0m`,     // Subtle gray border
};

/**
 * Registry of available themes.
 */
const themes: Record<string, Theme> = {
  lemon: lemonTheme,
  lime: limeTheme,
};

/**
 * The currently active theme.
 */
let currentTheme: Theme = themes.lemon;

/**
 * Switch to a different theme by name.
 * @param name The name of the theme to switch to
 * @returns true if the theme was found and switched, false otherwise
 */
function setTheme(name: string): boolean {
  const theme = themes[name];
  if (theme) {
    currentTheme = theme;
    return true;
  }
  return false;
}

/**
 * Get the name of the current theme.
 */
function getThemeName(): string {
  return currentTheme.name;
}

/**
 * Get the list of available theme names.
 */
function getAvailableThemes(): string[] {
  return Object.keys(themes);
}

// ============================================================================
// Lemon Mascot ASCII Art
// ============================================================================

/**
 * Cute lemon mascot for the welcome screen.
 * Uses colorful block characters with theme colors.
 */
function getLemonArt(): string {
  // Colors for different parts
  const y = ansi.primary;      // Yellow for lemon body
  const g = ansi.success;      // Green for leaf
  const d = ansi.primary;      // Darker yellow/orange for shading

  return [
    `       ${g('▄██▄')}`,
    `      ${y('▄')}${g('████')}${y('▄')}`,
    `     ${y('████████')}`,
    `    ${y('██')} ${d('◠')}  ${d('◠')} ${y('██')}`,
    `    ${y('██')}  ${d('‿')}   ${y('██')}`,
    `     ${y('████████')}`,
    `      ${y('▀████▀')}`,
  ].join('\n');
}

/**
 * Proxy object that delegates to the current theme.
 * This allows existing code to use `ansi.primary(...)` without changes.
 */
const ansi = {
  get primary() { return currentTheme.primary; },
  get secondary() { return currentTheme.secondary; },
  get success() { return currentTheme.success; },
  get warning() { return currentTheme.warning; },
  get error() { return currentTheme.error; },
  get muted() { return currentTheme.muted; },
  get dim() { return currentTheme.dim; },
  get bold() { return currentTheme.bold; },
  get italic() { return currentTheme.italic; },
  get modelineBg() { return currentTheme.modelineBg; },
  get overlayBg() { return currentTheme.overlayBg; },
  get border() { return currentTheme.border; },
};

// ============================================================================
// BorderBox Component
// ============================================================================

/**
 * BorderBox - a container with a thin Unicode border around its children.
 * Uses box-drawing characters for a clean, modern look.
 */
class BorderBox implements Component {
  children: Component[] = [];
  private borderFn: (s: string) => string;
  private bgFn?: (s: string) => string;

  constructor(borderFn: (s: string) => string, bgFn?: (s: string) => string) {
    this.borderFn = borderFn;
    this.bgFn = bgFn;
  }

  addChild(component: Component): void {
    this.children.push(component);
  }

  removeChild(component: Component): void {
    const index = this.children.indexOf(component);
    if (index !== -1) {
      this.children.splice(index, 1);
    }
  }

  invalidate(): void {
    for (const child of this.children) {
      child.invalidate?.();
    }
  }

  render(width: number): string[] {
    if (this.children.length === 0) {
      return [];
    }

    // Border characters (thin)
    const topLeft = '┌';
    const topRight = '┐';
    const bottomLeft = '└';
    const bottomRight = '┘';
    const horizontal = '─';
    const vertical = '│';

    // Content width is width minus 2 for borders, minus 2 for padding (1 each side)
    const contentWidth = Math.max(1, width - 4);
    const innerWidth = width - 2; // width inside borders

    // Render all children
    const childLines: string[] = [];
    for (const child of this.children) {
      const lines = child.render(contentWidth);
      for (const line of lines) {
        childLines.push(line);
      }
    }

    if (childLines.length === 0) {
      return [];
    }

    const result: string[] = [];

    // Top border
    const topBorder = topLeft + horizontal.repeat(innerWidth) + topRight;
    result.push(this.borderFn(topBorder));

    // Empty line for top padding
    result.push(this.renderPaddingLine(vertical, innerWidth));

    // Content lines with side borders and padding
    for (const line of childLines) {
      const lineWidth = visibleWidth(line);
      const padding = Math.max(0, contentWidth - lineWidth);
      const paddedLine = ' ' + line + ' '.repeat(padding + 1);

      // Apply background to content area if provided
      const content = this.bgFn ? this.applyBgToLine(paddedLine, innerWidth) : paddedLine;
      result.push(this.borderFn(vertical) + content + this.borderFn(vertical));
    }

    // Empty line for bottom padding
    result.push(this.renderPaddingLine(vertical, innerWidth));

    // Bottom border
    const bottomBorder = bottomLeft + horizontal.repeat(innerWidth) + bottomRight;
    result.push(this.borderFn(bottomBorder));

    return result;
  }

  private renderPaddingLine(vertical: string, innerWidth: number): string {
    const emptyContent = ' '.repeat(innerWidth);
    const content = this.bgFn ? this.bgFn(emptyContent) : emptyContent;
    return this.borderFn(vertical) + content + this.borderFn(vertical);
  }

  private applyBgToLine(line: string, targetWidth: number): string {
    if (!this.bgFn) return line;
    const lineWidth = visibleWidth(line);
    const padding = Math.max(0, targetWidth - lineWidth);
    return this.bgFn(line + ' '.repeat(padding));
  }
}

// ============================================================================
// Autocomplete Helpers
// ============================================================================

class RecentPathAutocompleteProvider implements AutocompleteProvider {
  private baseProvider: CombinedAutocompleteProvider;
  private recentItems: AutocompleteItem[];

  constructor(basePath: string, recentDirectories: string[]) {
    this.baseProvider = new CombinedAutocompleteProvider([], basePath);
    this.recentItems = recentDirectories.map((dir) => ({
      value: dir,
      label: dir,
      description: 'recent',
    }));
  }

  getSuggestions(
    lines: string[],
    cursorLine: number,
    cursorCol: number
  ): { items: AutocompleteItem[]; prefix: string } | null {
    const currentLine = lines[cursorLine] || '';
    const textBeforeCursor = currentLine.slice(0, cursorCol);

    if (textBeforeCursor.trim() === '') {
      if (this.recentItems.length === 0) return null;
      return { items: this.recentItems, prefix: '' };
    }

    return this.baseProvider.getSuggestions(lines, cursorLine, cursorCol);
  }

  applyCompletion(
    lines: string[],
    cursorLine: number,
    cursorCol: number,
    item: AutocompleteItem,
    prefix: string
  ): { lines: string[]; cursorLine: number; cursorCol: number } {
    if (prefix === '') {
      const nextLines = [...lines];
      nextLines[cursorLine] = item.value;
      return {
        lines: nextLines,
        cursorLine,
        cursorCol: item.value.length,
      };
    }

    return this.baseProvider.applyCompletion(lines, cursorLine, cursorCol, item, prefix);
  }
}

// Theme objects use wrapper functions to ensure they always use the current theme
const selectListTheme: SelectListTheme = {
  selectedPrefix: (s: string) => ansi.primary(s),
  selectedText: (s: string) => ansi.bold(s),
  description: (s: string) => ansi.muted(s),
  scrollInfo: (s: string) => ansi.muted(s),
  noMatch: (s: string) => ansi.muted(s),
};

const markdownTheme: MarkdownTheme = {
  heading: (s: string) => ansi.bold(ansi.primary(s)),
  link: (s: string) => ansi.primary(s),
  linkUrl: (s: string) => ansi.muted(s),
  code: (s: string) => ansi.warning(s),
  codeBlock: (s: string) => ansi.success(s),
  codeBlockBorder: (s: string) => ansi.muted(s),
  quote: (s: string) => ansi.italic(s),
  quoteBorder: (s: string) => ansi.muted(s),
  hr: (s: string) => ansi.muted(s),
  listBullet: (s: string) => ansi.primary(s),
  bold: (s: string) => ansi.bold(s),
  italic: (s: string) => ansi.italic(s),
  strikethrough: (s: string) => `\x1b[9m${s}\x1b[0m`,
  underline: (s: string) => `\x1b[4m${s}\x1b[0m`,
};

const editorTheme: EditorTheme = {
  borderColor: (s: string) => ansi.primary(s),
  selectList: selectListTheme,
};

// Note: settingsListTheme is created dynamically to support theme switching
function getSettingsListTheme(): SettingsListTheme {
  return {
    label: (text: string, selected: boolean) => selected ? ansi.bold(ansi.primary(text)) : text,
    value: (text: string, selected: boolean) => selected ? ansi.secondary(text) : ansi.muted(text),
    description: (s: string) => ansi.muted(s),
    cursor: ansi.primary('>'),
    hint: (s: string) => ansi.muted(s),
  };
}

const imageTheme: ImageTheme = {
  fallbackColor: (s: string) => ansi.muted(s),
};

const slashCommands: SlashCommand[] = [
  { name: 'abort', description: 'Stop the current operation' },
  { name: 'reset', description: 'Clear conversation and reset session' },
  { name: 'save', description: 'Save the current session' },
  { name: 'sessions', description: 'List saved sessions' },
  { name: 'resume', description: 'Resume a saved session' },
  { name: 'stats', description: 'Show session statistics' },
  { name: 'search', description: 'Search for text in conversations' },
  { name: 'settings', description: 'Open settings' },
  { name: 'debug', description: 'Toggle debug mode (on/off)' },
  { name: 'quit', description: 'Exit the application' },
  { name: 'exit', description: 'Exit the application' },
  { name: 'q', description: 'Exit the application' },
  { name: 'help', description: 'Show help message' },
  // Multi-session commands
  { name: 'running', description: 'List running sessions' },
  { name: 'new-session', description: 'Start a new session' },
  { name: 'switch', description: 'Switch to a different session' },
  { name: 'close-session', description: 'Close the current session' },
];

const MODELINE_PREFIXES = ['modeline:', 'modeline.'];
const GIT_STATUS_TIMEOUT_MS = 2000;
const GIT_REFRESH_INTERVAL_MS = 5000;

async function getGitModeline(cwd: string): Promise<string | null> {
  const output = await getGitStatusOutput(cwd);
  if (!output) {
    return null;
  }

  const lines = output.split(/\r?\n/);
  let head: string | null = null;
  let oid: string | null = null;
  let ahead = 0;
  let behind = 0;
  let dirty = false;

  for (const line of lines) {
    if (!line) {
      continue;
    }
    if (line.startsWith('# branch.head ')) {
      head = line.slice('# branch.head '.length).trim();
      continue;
    }
    if (line.startsWith('# branch.oid ')) {
      oid = line.slice('# branch.oid '.length).trim();
      continue;
    }
    if (line.startsWith('# branch.ab ')) {
      const match = line.match(/\+(\d+)\s+-(\d+)/);
      if (match) {
        ahead = Number.parseInt(match[1] || '0', 10);
        behind = Number.parseInt(match[2] || '0', 10);
      }
      continue;
    }
    if (!line.startsWith('#')) {
      dirty = true;
    }
  }

  if (!head && !oid) {
    return null;
  }

  let branch = head;
  if (branch === '(detached)' || branch === 'HEAD' || !branch) {
    const shortOid = oid ? oid.slice(0, 7) : '';
    branch = shortOid || 'detached';
  }

  let suffix = '';
  if (ahead > 0) {
    suffix += ` +${ahead}`;
  }
  if (behind > 0) {
    suffix += ` -${behind}`;
  }
  if (dirty) {
    suffix += ' *';
  }

  return `${branch}${suffix}`;
}

function getGitStatusOutput(cwd: string): Promise<string | null> {
  return new Promise((resolve) => {
    execFile(
      'git',
      ['status', '--porcelain=v2', '--branch'],
      { cwd, timeout: GIT_STATUS_TIMEOUT_MS, maxBuffer: 1024 * 1024 },
      (err, stdout) => {
        if (err) {
          resolve(null);
          return;
        }
        const trimmed = stdout.trim();
        resolve(trimmed || null);
      }
    );
  });
}

// ============================================================================
// Main Application
// ============================================================================

class LemonTUI {
  private tui: TUI;
  private connection: AgentConnection;
  private connectionOptions: AgentConnectionOptions;
  private store: StateStore;

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

  private handleRunningSessions(msg: { type: 'running_sessions'; sessions: Array<{ session_id: string; cwd: string; is_streaming: boolean }>; error?: string | null }): void {
    if (msg.error) {
      this.store.setError(`Failed to list running sessions: ${msg.error}`);
      return;
    }
    this.store.setRunningSessions(msg.sessions);

    // Ensure any unknown sessions are tracked locally
    const state = this.store.getState();
    for (const session of msg.sessions) {
      if (!this.store.getSession(session.session_id)) {
        this.store.handleSessionStarted(session.session_id, session.cwd, state.model);
      }
    }

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

  private showRunningSessionsOverlay(sessions: Array<{ session_id: string; cwd: string; is_streaming: boolean }>): void {
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
    const showToolResults = !this.toolPanelCollapsed;

    this.messagesContainer.clear();

    for (const msg of state.messages) {
      if (msg.type === 'tool_result' && !showToolResults) {
        continue;
      }
      const component = this.createMessageComponent(msg);
      this.messagesContainer.addChild(component);
    }

    if (state.streamingMessage) {
      this.streamingComponent = this.createMessageComponent(state.streamingMessage);
      this.messagesContainer.addChild(this.streamingComponent);
    } else {
      this.streamingComponent = null;
    }
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

        // Stop reason indicator (only for non-normal completions)
        if (!assistant.isStreaming && assistant.stopReason) {
          if (assistant.stopReason === 'length') {
            lines.push(ansi.warning('[truncated]'));
          } else if (assistant.stopReason === 'error') {
            lines.push(ansi.error('[error]'));
          } else if (assistant.stopReason === 'aborted') {
            lines.push(ansi.error('[aborted]'));
          }
          // 'stop' and 'tool_use' are normal - don't show anything
        }

        return new Markdown(lines.join('\n'), 1, 1, markdownTheme);
      }

      case 'tool_result': {
        const toolResult = message as NormalizedToolResultMessage;
        const colorFn = toolResult.isError ? ansi.error : ansi.secondary;
        const content = toolResult.content.length > 500
          ? toolResult.content.slice(0, 500) + '...'
          : toolResult.content;

        // If there are no images, return a simple Text component
        if (!toolResult.images || toolResult.images.length === 0) {
          return new Text(colorFn(`[${toolResult.toolName}] ${content}`), 1, 1);
        }

        // Otherwise, use a Container to render text and images
        const container = new Container();

        // Add text content first
        if (content) {
          container.addChild(new Text(colorFn(`[${toolResult.toolName}] ${content}`), 1, 1));
        } else {
          container.addChild(new Text(colorFn(`[${toolResult.toolName}]`), 1, 0));
        }

        // Add each image
        for (const img of toolResult.images) {
          const imageComponent = new Image(img.data, img.mimeType, imageTheme, {
            maxWidthCells: 80,
            maxHeightCells: 40,
          });
          container.addChild(imageComponent);
        }

        return container;
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

    const contentContainer = new Container();
    contentContainer.addChild(titleText);
    contentContainer.addChild(selectList);

    const box = new BorderBox(ansi.border, ansi.overlayBg);
    box.addChild(contentContainer);

    this.overlayHandle = this.tui.showOverlay(box, {
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

    const contentContainer = new Container();
    contentContainer.addChild(header);
    contentContainer.addChild(selectList);

    const box = new BorderBox(ansi.border, ansi.overlayBg);
    box.addChild(contentContainer);

    this.overlayHandle = this.tui.showOverlay(box, {
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

    const contentContainer = new Container();
    contentContainer.addChild(header);
    contentContainer.addChild(input);

    const box = new BorderBox(ansi.border, ansi.overlayBg);
    box.addChild(contentContainer);

    this.overlayHandle = this.tui.showOverlay(box, {
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

    const contentContainer = new Container();
    contentContainer.addChild(header);
    contentContainer.addChild(editorOverlay);

    const box = new BorderBox(ansi.border, ansi.overlayBg);
    box.addChild(contentContainer);

    this.overlayHandle = this.tui.showOverlay(box, {
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

  private showLocalSelectOverlay(
    title: string,
    items: SelectItem[],
    onSelect: (item: SelectItem) => void
  ): void {
    if (this.overlayHandle) {
      return;
    }

    const titleText = new Text(ansi.bold(title), 1, 0);
    const selectList = new SelectList(items, Math.min(10, items.length), selectListTheme);

    selectList.onSelect = (item: SelectItem) => {
      onSelect(item);
      this.hideLocalOverlay();
    };

    selectList.onCancel = () => {
      this.hideLocalOverlay();
    };

    const contentContainer = new Container();
    contentContainer.addChild(titleText);
    contentContainer.addChild(selectList);

    const box = new BorderBox(ansi.border, ansi.overlayBg);
    box.addChild(contentContainer);

    this.currentOverlayRequestId = '__local__';
    this.overlayHandle = this.tui.showOverlay(box, {
      width: '80%',
      maxHeight: '60%',
      anchor: 'center',
    });
    this.tui.setFocus(selectList);
  }

  private showLocalInputOverlay(
    title: string,
    prefill: string,
    onSubmit: (value: string) => void
  ): void {
    if (this.overlayHandle) {
      return;
    }

    const header = new Text(ansi.bold(title), 1, 0);
    const input = new Input();

    if (prefill) {
      input.setValue(prefill);
    }

    input.onSubmit = (text: string) => {
      this.hideLocalOverlay();
      onSubmit(text);
    };

    input.onEscape = () => {
      this.hideLocalOverlay();
    };

    const contentContainer = new Container();
    contentContainer.addChild(header);
    contentContainer.addChild(input);

    const box = new BorderBox(ansi.border, ansi.overlayBg);
    box.addChild(contentContainer);

    this.currentOverlayRequestId = '__local__';
    this.overlayHandle = this.tui.showOverlay(box, {
      width: '80%',
      anchor: 'center',
    });
    this.tui.setFocus(input);
  }

  private showLocalPathInputOverlay(
    title: string,
    prefill: string,
    recentDirectories: string[],
    onSubmit: (value: string) => void
  ): void {
    if (this.overlayHandle) {
      return;
    }

    const header = new Text(
      `${ansi.bold(title)}\n${ansi.muted('Enter to submit, Esc to cancel')}`,
      1,
      0
    );
    const editor = new Editor(this.tui, editorTheme);

    if (prefill) {
      editor.setText(prefill);
    }

    const basePath = this.store.getState().cwd || process.cwd();
    editor.setAutocompleteProvider(
      new RecentPathAutocompleteProvider(basePath, recentDirectories)
    );

    editor.onSubmit = (text: string) => {
      this.hideLocalOverlay();
      onSubmit(text.trim());
    };

    const originalHandleInput = editor.handleInput?.bind(editor);
    editor.handleInput = (data: string) => {
      if (matchesKey(data, 'escape')) {
        this.hideLocalOverlay();
        return;
      }
      originalHandleInput?.(data);
    };

    const contentContainer = new Container();
    contentContainer.addChild(header);
    contentContainer.addChild(editor);

    const box = new BorderBox(ansi.border, ansi.overlayBg);
    box.addChild(contentContainer);

    this.currentOverlayRequestId = '__local__';
    this.overlayHandle = this.tui.showOverlay(box, {
      width: '90%',
      maxHeight: '60%',
      anchor: 'center',
    });
    this.tui.setFocus(editor);
  }

  private hideLocalOverlay(): void {
    if (this.overlayHandle) {
      this.overlayHandle.hide();
      this.overlayHandle = null;
    }
    this.currentOverlayRequestId = null;

    const currentRequest = this.store.getCurrentUIRequest();
    if (currentRequest) {
      this.showUIOverlay(currentRequest);
    } else {
      const state = this.store.getState();
      if (!state.activeSessionId && this.sessionsList) {
        this.tui.setFocus(this.sessionsList);
      } else {
        this.tui.setFocus(this.inputEditor);
      }
    }
  }

  private showSettingsOverlay(): void {
    const state = this.store.getState();

    // Get available themes and format them for display (capitalize first letter)
    const availableThemeNames = getAvailableThemes();
    const formatThemeName = (name: string) => name.charAt(0).toUpperCase() + name.slice(1);
    const themeValues = availableThemeNames.map(formatThemeName);

    const items: SettingItem[] = [
      {
        id: 'debug',
        label: 'Debug Mode',
        description: 'Enable debug logging and diagnostics',
        currentValue: state.debug ? 'On' : 'Off',
        values: ['On', 'Off'],
      },
      {
        id: 'theme',
        label: 'Theme',
        description: 'Color theme for the TUI',
        currentValue: formatThemeName(getThemeName()),
        values: themeValues,
      },
      {
        id: 'model',
        label: 'Model',
        description: 'Current AI model provider and ID',
        currentValue: state.ready ? `${state.model.provider}:${state.model.id}` : 'Not connected',
      },
      {
        id: 'cwd',
        label: 'Working Directory',
        description: 'Current working directory for the agent',
        currentValue: state.cwd || process.cwd(),
      },
    ];

    const titleText = new Text(ansi.bold('Settings'), 1, 0);
    const settingsList = new SettingsList(
      items,
      Math.min(10, items.length + 2),
      getSettingsListTheme(),
      (id: string, newValue: string) => {
        // Handle setting changes
        if (id === 'debug') {
          const debugEnabled = newValue === 'On';
          this.store.setDebug(debugEnabled);
          settingsList.updateValue('debug', debugEnabled ? 'On' : 'Off');
          saveTUIConfigKey('debug', debugEnabled);  // Persist to config file
        } else if (id === 'theme') {
          // Convert display name back to theme key (lowercase)
          const themeName = newValue.toLowerCase();
          if (setTheme(themeName)) {
            settingsList.updateValue('theme', newValue);
            // Request a full re-render to apply the new theme
            this.tui.requestRender();
            saveTUIConfigKey('theme', themeName);  // Persist to config file
          }
        }
        // Other settings are info-only for now
      },
      () => {
        // onCancel
        this.hideSettingsOverlay();
      }
    );

    const contentContainer = new Container();
    contentContainer.addChild(titleText);
    contentContainer.addChild(settingsList);

    const box = new BorderBox(ansi.border, ansi.overlayBg);
    box.addChild(contentContainer);

    this.overlayHandle = this.tui.showOverlay(box, {
      width: '80%',
      maxHeight: '60%',
      anchor: 'center',
    });
    this.tui.setFocus(settingsList);
  }

  private hideSettingsOverlay(): void {
    if (this.overlayHandle) {
      this.overlayHandle.hide();
      this.overlayHandle = null;
    }
    this.tui.setFocus(this.inputEditor);
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

// ============================================================================
// CLI Entry Point
// ============================================================================

interface CLIArgs {
  cwd?: string;
  model?: string;
  provider?: string;
  baseUrl?: string;
  systemPrompt?: string;
  sessionFile?: string;
  debug?: boolean;
  ui?: boolean;
  lemonPath?: string;
}

function parseArgs(): CLIArgs {
  const args = process.argv.slice(2);
  const options: CLIArgs = {};

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

      case '--provider':
      case '-p':
        options.provider = args[++i];
        break;

      case '--base-url':
        options.baseUrl = args[++i];
        break;

      case '--system-prompt':
        options.systemPrompt = args[++i];
        break;

      case '--session-file':
        options.sessionFile = args[++i];
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
  --model, -m <spec>     Model specification (provider:model_id or just model_id)
  --provider, -p <name>  Provider name (anthropic, openai, kimi, etc.)
  --base-url <url>       Base URL override for model provider
  --system-prompt <text> Custom system prompt
  --session-file <path>  Resume session from file
  --debug                Enable debug mode
  --no-ui                Disable UI overlays
  --lemon-path <path>    Path to lemon project root
  --help, -h             Show this help message

Configuration:
  Config file: ~/.lemon/config.json
  Environment variables override config file values.
  CLI arguments override everything.
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

/**
 * Build AgentConnectionOptions from CLI args and resolved config
 */
function buildOptions(cliArgs: CLIArgs, config: ResolvedConfig): AgentConnectionOptions {
  const options: AgentConnectionOptions = {
    cwd: cliArgs.cwd,
    debug: config.debug,
    ui: cliArgs.ui,
    lemonPath: cliArgs.lemonPath,
    systemPrompt: cliArgs.systemPrompt,
    sessionFile: cliArgs.sessionFile,
  };

  // Build model string - if CLI provided full "provider:model", use that
  // Otherwise, use resolved config
  options.model = getModelString(config);

  // Base URL from config (already resolved with precedence)
  if (config.baseUrl) {
    options.baseUrl = config.baseUrl;
  }

  return options;
}

// Main
const cliArgs = parseArgs();

// If model includes provider prefix, parse and override provider/model for resolution
const modelSpec = parseModelSpec(cliArgs.model);
if (modelSpec.provider) {
  cliArgs.provider = modelSpec.provider;
}
if (modelSpec.model) {
  cliArgs.model = modelSpec.model;
}

// Resolve configuration: CLI args > env vars > config file
const resolvedConfig = resolveConfig({
  provider: cliArgs.provider,
  model: cliArgs.model,
  baseUrl: cliArgs.baseUrl,
  debug: cliArgs.debug,
});

// Apply theme from resolved config
setTheme(resolvedConfig.theme);

// Build final options for the TUI
const options = buildOptions(cliArgs, resolvedConfig);

const app = new LemonTUI(options);
app.start();
