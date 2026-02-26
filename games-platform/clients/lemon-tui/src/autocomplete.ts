/**
 * Autocomplete helpers for the Lemon TUI.
 */

import {
  CombinedAutocompleteProvider,
  type AutocompleteProvider,
  type AutocompleteItem,
} from '@mariozechner/pi-tui';

/**
 * RecentPathAutocompleteProvider - An autocomplete provider that shows recent directories
 * when the input is empty, and falls back to file path completion otherwise.
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
