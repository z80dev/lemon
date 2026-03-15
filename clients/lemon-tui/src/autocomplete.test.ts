/**
 * Tests for the autocomplete providers.
 */

import { describe, it, expect } from 'vitest';
import {
  SlashCommandAutocompleteProvider,
  CombinedAutocompleteProvider,
  RecentPathAutocompleteProvider,
} from './autocomplete.js';
import type { SlashCommand } from './ink/types.js';

const testCommands: SlashCommand[] = [
  { name: 'help', description: 'Show help' },
  { name: 'quit', description: 'Exit application' },
  { name: 'reset', description: 'Reset session' },
  { name: 'resume', description: 'Resume session' },
  { name: 'save', description: 'Save session' },
];

describe('SlashCommandAutocompleteProvider', () => {
  const provider = new SlashCommandAutocompleteProvider(testCommands);

  describe('getSuggestions', () => {
    it('should return all commands when just / is typed', () => {
      const result = provider.getSuggestions(['/'], 0, 1);
      expect(result).not.toBeNull();
      expect(result!.items).toHaveLength(5);
      expect(result!.prefix).toBe('/');
    });

    it('should filter commands by prefix', () => {
      const result = provider.getSuggestions(['/re'], 0, 3);
      expect(result).not.toBeNull();
      expect(result!.items).toHaveLength(2); // reset, resume
      expect(result!.items.map((i) => i.label)).toEqual(['/reset', '/resume']);
      expect(result!.prefix).toBe('/re');
    });

    it('should return single match for unique prefix', () => {
      const result = provider.getSuggestions(['/h'], 0, 2);
      expect(result).not.toBeNull();
      expect(result!.items).toHaveLength(1);
      expect(result!.items[0].label).toBe('/help');
    });

    it('should return null for non-slash input', () => {
      expect(provider.getSuggestions(['hello'], 0, 5)).toBeNull();
    });

    it('should return null when no commands match', () => {
      expect(provider.getSuggestions(['/xyz'], 0, 4)).toBeNull();
    });

    it('should be case insensitive', () => {
      const result = provider.getSuggestions(['/H'], 0, 2);
      expect(result).not.toBeNull();
      expect(result!.items).toHaveLength(1);
      expect(result!.items[0].label).toBe('/help');
    });

    it('should not match if there are characters after a space', () => {
      expect(provider.getSuggestions(['/help foo'], 0, 9)).toBeNull();
    });

    it('should work with cursor in the middle of text', () => {
      // Cursor at position 2 in '/he'
      const result = provider.getSuggestions(['/help'], 0, 2);
      expect(result).not.toBeNull();
      expect(result!.prefix).toBe('/h');
    });

    it('should handle empty line', () => {
      expect(provider.getSuggestions([''], 0, 0)).toBeNull();
    });

    it('should include descriptions in items', () => {
      const result = provider.getSuggestions(['/'], 0, 1);
      expect(result!.items[0].description).toBe('Show help');
    });

    it('should set value equal to label', () => {
      const result = provider.getSuggestions(['/'], 0, 1);
      for (const item of result!.items) {
        expect(item.value).toBe(item.label);
      }
    });
  });

  describe('applyCompletion', () => {
    it('should replace the current line with the selected command', () => {
      const items = provider.getSuggestions(['/re'], 0, 3)!.items;
      const result = provider.applyCompletion(['/re'], 0, 3, items[0], '/re');
      expect(result.lines[0]).toBe('/reset');
      expect(result.cursorCol).toBe(6);
      expect(result.cursorLine).toBe(0);
    });

    it('should work with full prefix', () => {
      const items = provider.getSuggestions(['/'], 0, 1)!.items;
      const helpItem = items.find((i) => i.label === '/help')!;
      const result = provider.applyCompletion(['/'], 0, 1, helpItem, '/');
      expect(result.lines[0]).toBe('/help');
      expect(result.cursorCol).toBe(5);
    });
  });
});

describe('CombinedAutocompleteProvider', () => {
  const provider = new CombinedAutocompleteProvider(testCommands, '/test/dir');

  it('should provide slash command suggestions', () => {
    const result = provider.getSuggestions(['/h'], 0, 2);
    expect(result).not.toBeNull();
    expect(result!.items[0].label).toBe('/help');
  });

  it('should return null for non-slash input', () => {
    expect(provider.getSuggestions(['hello'], 0, 5)).toBeNull();
  });

  it('should apply slash command completions', () => {
    const suggestions = provider.getSuggestions(['/h'], 0, 2)!;
    const result = provider.applyCompletion(['/h'], 0, 2, suggestions.items[0], suggestions.prefix);
    expect(result.lines[0]).toBe('/help');
  });
});

describe('RecentPathAutocompleteProvider', () => {
  describe('with recent directories', () => {
    const recentDirs = ['/home/user/project1', '/home/user/project2'];
    const provider = new RecentPathAutocompleteProvider('/test', recentDirs);

    it('should show recent directories when input is empty', () => {
      const result = provider.getSuggestions([''], 0, 0);
      expect(result).not.toBeNull();
      expect(result!.items).toHaveLength(2);
      expect(result!.items[0].value).toBe('/home/user/project1');
      expect(result!.items[0].description).toBe('recent');
      expect(result!.prefix).toBe('');
    });

    it('should show recent directories for whitespace-only input', () => {
      const result = provider.getSuggestions(['   '], 0, 3);
      expect(result).not.toBeNull();
      expect(result!.items).toHaveLength(2);
    });

    it('should apply recent directory completion', () => {
      const result = provider.getSuggestions([''], 0, 0)!;
      const applied = provider.applyCompletion([''], 0, 0, result.items[0], '');
      expect(applied.lines[0]).toBe('/home/user/project1');
      expect(applied.cursorCol).toBe('/home/user/project1'.length);
    });

    it('should fall back to slash commands when text is entered', () => {
      const result = provider.getSuggestions(['/'], 0, 1);
      // This delegates to CombinedAutocompleteProvider which has no commands
      expect(result).toBeNull();
    });
  });

  describe('without recent directories', () => {
    const provider = new RecentPathAutocompleteProvider('/test', []);

    it('should return null for empty input when no recent dirs', () => {
      expect(provider.getSuggestions([''], 0, 0)).toBeNull();
    });
  });
});
