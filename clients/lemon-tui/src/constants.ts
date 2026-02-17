/**
 * Constants used throughout the Lemon TUI application.
 */

import type { SlashCommand } from '@mariozechner/pi-tui';

export const slashCommands: SlashCommand[] = [
  { name: 'abort', description: 'Stop the current operation' },
  { name: 'reset', description: 'Clear conversation and reset session' },
  { name: 'save', description: 'Save the current session' },
  { name: 'sessions', description: 'List saved sessions' },
  { name: 'resume', description: 'Resume a saved session' },
  { name: 'stats', description: 'Show session statistics' },
  { name: 'search', description: 'Search for text in conversations' },
  { name: 'settings', description: 'Open settings' },
  { name: 'debug', description: 'Toggle debug mode (on/off)' },
  { name: 'restart', description: 'Restart the Lemon agent process (reloads latest code)' },
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

export const MODELINE_PREFIXES = ['modeline:', 'modeline.'];
export const GIT_STATUS_TIMEOUT_MS = 2000;
export const GIT_REFRESH_INTERVAL_MS = 5000;

/** Braille spinner frames for tool execution animation. */
export const SPINNER_FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

/** Tool category for color coding in tool panel. Values: 'file', 'shell', 'search', 'orchestration'. */
export const TOOL_CATEGORIES: Record<string, string> = {
  read: 'file',
  write: 'file',
  edit: 'file',
  multiedit: 'file',
  patch: 'file',
  find: 'file',
  glob: 'file',
  ls: 'file',
  bash: 'shell',
  exec: 'shell',
  grep: 'search',
  websearch: 'search',
  webfetch: 'search',
  task: 'orchestration',
  process: 'orchestration',
  todo: 'orchestration',
  todoread: 'orchestration',
  todowrite: 'orchestration',
};

/** Auto-dismiss timeout for error bars (ms). */
export const ERROR_DISMISS_MS = 5000;
