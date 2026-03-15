/**
 * Autocomplete helpers for the Lemon TUI.
 */

import * as fs from 'fs';
import * as path from 'path';
import type { AutocompleteProvider, AutocompleteItem, SlashCommand } from './ink/types.js';

/**
 * SlashCommandAutocompleteProvider - provides autocomplete for slash commands.
 */
export class SlashCommandAutocompleteProvider implements AutocompleteProvider {
  private commands: SlashCommand[];

  constructor(commands: SlashCommand[]) {
    this.commands = commands;
  }

  getSuggestions(
    lines: string[],
    cursorLine: number,
    cursorCol: number
  ): { items: AutocompleteItem[]; prefix: string } | null {
    const currentLine = lines[cursorLine] || '';
    const textBeforeCursor = currentLine.slice(0, cursorCol);

    // Only trigger on lines starting with /
    const match = textBeforeCursor.match(/^\/(\S*)$/);
    if (!match) return null;

    const prefix = match[1].toLowerCase();
    const items = this.commands
      .filter((cmd) => cmd.name.toLowerCase().startsWith(prefix))
      .map((cmd) => ({
        value: `/${cmd.name}`,
        label: `/${cmd.name}`,
        description: cmd.description,
      }));

    if (items.length === 0) return null;
    return { items, prefix: `/${prefix}` };
  }

  applyCompletion(
    lines: string[],
    cursorLine: number,
    _cursorCol: number,
    item: AutocompleteItem,
    _prefix: string
  ): { lines: string[]; cursorLine: number; cursorCol: number } {
    const nextLines = [...lines];
    nextLines[cursorLine] = item.value;
    return {
      lines: nextLines,
      cursorLine,
      cursorCol: item.value.length,
    };
  }
}

/**
 * FileAutocompleteProvider - provides filesystem path completion.
 */
export class FileAutocompleteProvider implements AutocompleteProvider {
  private basePath: string;

  constructor(basePath: string) {
    this.basePath = basePath;
  }

  getSuggestions(
    lines: string[],
    cursorLine: number,
    cursorCol: number
  ): { items: AutocompleteItem[]; prefix: string } | null {
    const currentLine = lines[cursorLine] || '';
    const textBeforeCursor = currentLine.slice(0, cursorCol);

    // Don't trigger on slash commands
    if (textBeforeCursor.startsWith('/')) return null;

    // Extract the last word/path token before cursor
    const tokenMatch = textBeforeCursor.match(/(~?[\w./-]+)$/);
    if (!tokenMatch) return null;

    const token = tokenMatch[1];

    // Expand ~ to home dir
    let expandedToken = token;
    if (expandedToken.startsWith('~')) {
      expandedToken = expandedToken.replace(/^~/, process.env.HOME || '');
    }

    // Resolve the path
    const resolved = path.isAbsolute(expandedToken)
      ? expandedToken
      : path.join(this.basePath, expandedToken);

    // Determine the directory to list and the prefix to filter
    let dir: string;
    let filePrefix: string;

    try {
      const stat = fs.statSync(resolved);
      if (stat.isDirectory()) {
        // If token ends with /, list contents; otherwise complete the directory name
        if (token.endsWith('/')) {
          dir = resolved;
          filePrefix = '';
        } else {
          // Complete as a directory (add trailing /)
          dir = path.dirname(resolved);
          filePrefix = path.basename(resolved);
        }
      } else {
        // It's a file — complete siblings with same prefix
        dir = path.dirname(resolved);
        filePrefix = path.basename(resolved);
      }
    } catch {
      // Path doesn't exist — use parent dir and basename as prefix
      dir = path.dirname(resolved);
      filePrefix = path.basename(resolved);
    }

    // List directory contents
    let entries: string[];
    try {
      entries = fs.readdirSync(dir);
    } catch {
      return null;
    }

    // Filter by prefix
    const filtered = entries
      .filter((e) => e.startsWith(filePrefix) && !e.startsWith('.'))
      .slice(0, 12);

    if (filtered.length === 0) return null;

    const tokenDir = token.endsWith('/')
      ? token
      : token.includes('/')
        ? token.slice(0, token.lastIndexOf('/') + 1)
        : '';

    const items: AutocompleteItem[] = filtered.map((entry) => {
      const fullPath = path.join(dir, entry);
      let isDir = false;
      try {
        isDir = fs.statSync(fullPath).isDirectory();
      } catch { /* ignore */ }

      const completedValue = tokenDir + entry + (isDir ? '/' : '');
      return {
        value: completedValue,
        label: entry + (isDir ? '/' : ''),
        description: isDir ? 'dir' : undefined,
      };
    });

    return { items, prefix: token };
  }

  applyCompletion(
    lines: string[],
    cursorLine: number,
    cursorCol: number,
    item: AutocompleteItem,
    prefix: string
  ): { lines: string[]; cursorLine: number; cursorCol: number } {
    const currentLine = lines[cursorLine] || '';
    const beforePrefix = currentLine.slice(0, cursorCol - prefix.length);
    const afterCursor = currentLine.slice(cursorCol);
    const newLine = beforePrefix + item.value + afterCursor;

    const nextLines = [...lines];
    nextLines[cursorLine] = newLine;
    return {
      lines: nextLines,
      cursorLine,
      cursorCol: beforePrefix.length + item.value.length,
    };
  }
}

/**
 * CombinedAutocompleteProvider - combines slash command and path autocomplete.
 * Slash commands take priority; file paths complete for non-slash tokens.
 */
export class CombinedAutocompleteProvider implements AutocompleteProvider {
  private slashProvider: SlashCommandAutocompleteProvider;
  private fileProvider: FileAutocompleteProvider;

  constructor(commands: SlashCommand[], basePath: string) {
    this.slashProvider = new SlashCommandAutocompleteProvider(commands);
    this.fileProvider = new FileAutocompleteProvider(basePath);
  }

  getSuggestions(
    lines: string[],
    cursorLine: number,
    cursorCol: number
  ): { items: AutocompleteItem[]; prefix: string } | null {
    // Try slash commands first
    const slashResult = this.slashProvider.getSuggestions(lines, cursorLine, cursorCol);
    if (slashResult) return slashResult;

    // Fall back to file path completion
    return this.fileProvider.getSuggestions(lines, cursorLine, cursorCol);
  }

  applyCompletion(
    lines: string[],
    cursorLine: number,
    cursorCol: number,
    item: AutocompleteItem,
    prefix: string
  ): { lines: string[]; cursorLine: number; cursorCol: number } {
    // If prefix starts with /, it's a slash command
    if (prefix.startsWith('/')) {
      return this.slashProvider.applyCompletion(lines, cursorLine, cursorCol, item, prefix);
    }
    // Otherwise it's a file path
    return this.fileProvider.applyCompletion(lines, cursorLine, cursorCol, item, prefix);
  }
}

/**
 * RecentPathAutocompleteProvider - An autocomplete provider that shows recent directories
 * when the input is empty, and falls back to combined completion otherwise.
 */
export class RecentPathAutocompleteProvider implements AutocompleteProvider {
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
