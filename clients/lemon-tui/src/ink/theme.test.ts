/**
 * Tests for the Ink theme system.
 */

import { describe, it, expect } from 'vitest';
import { getInkTheme, inkThemes, type InkTheme } from './theme.js';

describe('Ink theme system', () => {
  describe('inkThemes', () => {
    it('should have all six themes', () => {
      expect(Object.keys(inkThemes)).toEqual(['lemon', 'lime', 'midnight', 'rose', 'ocean', 'contrast']);
    });

    it('each theme should have all required color keys', () => {
      const requiredKeys: (keyof InkTheme)[] = [
        'name', 'primary', 'secondary', 'accent', 'success',
        'warning', 'error', 'muted', 'border', 'modelineBg', 'overlayBg',
      ];

      for (const [name, theme] of Object.entries(inkThemes)) {
        for (const key of requiredKeys) {
          expect(theme[key], `${name}.${key} should be defined`).toBeDefined();
          expect(typeof theme[key]).toBe('string');
        }
      }
    });

    it('each theme name should match its key', () => {
      for (const [key, theme] of Object.entries(inkThemes)) {
        expect(theme.name).toBe(key);
      }
    });

    it('color values should use ansi256 format', () => {
      for (const [, theme] of Object.entries(inkThemes)) {
        for (const [key, value] of Object.entries(theme)) {
          if (key === 'name') continue;
          expect(value, `${theme.name}.${key}`).toMatch(/^ansi256\(\d+\)$/);
        }
      }
    });
  });

  describe('getInkTheme', () => {
    it('should return the correct theme by name', () => {
      expect(getInkTheme('lemon').name).toBe('lemon');
      expect(getInkTheme('midnight').name).toBe('midnight');
      expect(getInkTheme('ocean').name).toBe('ocean');
    });

    it('should fall back to lemon for unknown theme names', () => {
      expect(getInkTheme('nonexistent').name).toBe('lemon');
      expect(getInkTheme('')).toEqual(inkThemes.lemon);
    });

    it('should return unique primary colors per theme', () => {
      const primaries = Object.values(inkThemes).map((t) => t.primary);
      const unique = new Set(primaries);
      expect(unique.size).toBe(primaries.length);
    });
  });

  describe('theme color uniqueness', () => {
    it('primary and accent should be different in each theme', () => {
      for (const theme of Object.values(inkThemes)) {
        expect(theme.primary, `${theme.name}: primary !== accent`).not.toBe(theme.accent);
      }
    });

    it('success and error should be different in each theme', () => {
      for (const theme of Object.values(inkThemes)) {
        expect(theme.success, `${theme.name}: success !== error`).not.toBe(theme.error);
      }
    });
  });
});
