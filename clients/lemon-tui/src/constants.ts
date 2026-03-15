/**
 * Constants used throughout the Lemon TUI application.
 */

import type { SlashCommand } from './ink/types.js';

export const slashCommands: SlashCommand[] = [
  { name: 'abort', description: 'Stop the current operation' },
  { name: 'reset', description: 'Clear conversation and reset session' },
  { name: 'save', description: 'Save the current session' },
  { name: 'sessions', description: 'List saved sessions' },
  { name: 'resume', description: 'Resume a saved session' },
  { name: 'stats', description: 'Show session statistics' },
  { name: 'search', description: 'Search messages (Ctrl+F)' },
  { name: 'settings', description: 'Open settings' },
  { name: 'debug', description: 'Toggle debug mode (on/off)' },
  { name: 'restart', description: 'Restart the Lemon agent process (reloads latest code)' },
  { name: 'quit', description: 'Exit the application' },
  { name: 'exit', description: 'Exit the application' },
  { name: 'q', description: 'Exit the application' },
  { name: 'help', description: 'Show help overlay' },
  { name: 'compact', description: 'Toggle compact display mode' },
  { name: 'bell', description: 'Toggle terminal bell on completion' },
  { name: 'notifications', description: 'Show notification history' },
  // Multi-session commands
  { name: 'running', description: 'List running sessions' },
  { name: 'new-session', description: 'Start a new session' },
  { name: 'switch', description: 'Switch to a different session' },
  { name: 'close-session', description: 'Close the current session' },
  { name: 'edit', description: 'Edit and resend last message' },
  { name: 'copy', description: 'Copy last code block to clipboard' },
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
