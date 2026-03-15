/**
 * Local type definitions replacing @mariozechner/pi-tui imports.
 */

/** Slash command for autocomplete. */
export interface SlashCommand {
  name: string;
  description: string;
}

/** An autocomplete suggestion item. */
export interface AutocompleteItem {
  value: string;
  label: string;
  description?: string;
}

/** Autocomplete provider interface. */
export interface AutocompleteProvider {
  getSuggestions(
    lines: string[],
    cursorLine: number,
    cursorCol: number
  ): { items: AutocompleteItem[]; prefix: string } | null;

  applyCompletion(
    lines: string[],
    cursorLine: number,
    cursorCol: number,
    item: AutocompleteItem,
    prefix: string
  ): { lines: string[]; cursorLine: number; cursorCol: number };
}

/** A select list item. */
export interface SelectItem {
  label: string;
  value: string;
  description?: string;
}
