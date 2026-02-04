import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  setTheme,
  getThemeName,
  getAvailableThemes,
  getCurrentTheme,
  ansi,
  lemonTheme,
  limeTheme,
  type Theme,
} from './theme.js';

describe('Theme system', () => {
  // Reset to lemon theme before each test for consistency
  beforeEach(() => {
    setTheme('lemon');
  });

  afterEach(() => {
    // Reset to default theme after each test
    setTheme('lemon');
  });

  describe('setTheme', () => {
    it('switches to lemon theme', () => {
      setTheme('lime'); // First switch away
      const result = setTheme('lemon');
      expect(result).toBe(true);
      expect(getThemeName()).toBe('lemon');
    });

    it('switches to lime theme', () => {
      const result = setTheme('lime');
      expect(result).toBe(true);
      expect(getThemeName()).toBe('lime');
    });

    it('returns false for non-existent theme', () => {
      const result = setTheme('nonexistent');
      expect(result).toBe(false);
      // Theme should remain unchanged
      expect(getThemeName()).toBe('lemon');
    });

    it('returns false for empty string', () => {
      const result = setTheme('');
      expect(result).toBe(false);
      expect(getThemeName()).toBe('lemon');
    });

    it('handles case sensitivity', () => {
      const result = setTheme('LEMON');
      expect(result).toBe(false); // Theme names are case-sensitive
      expect(getThemeName()).toBe('lemon');
    });
  });

  describe('getThemeName', () => {
    it('returns current theme name', () => {
      expect(getThemeName()).toBe('lemon');
    });

    it('returns updated theme name after switching', () => {
      setTheme('lime');
      expect(getThemeName()).toBe('lime');
    });

    it('returns lemon after switching back', () => {
      setTheme('lime');
      setTheme('lemon');
      expect(getThemeName()).toBe('lemon');
    });
  });

  describe('getAvailableThemes', () => {
    it('returns array of available theme names', () => {
      const themes = getAvailableThemes();
      expect(Array.isArray(themes)).toBe(true);
      expect(themes).toContain('lemon');
      expect(themes).toContain('lime');
    });

    it('returns at least 2 themes', () => {
      const themes = getAvailableThemes();
      expect(themes.length).toBeGreaterThanOrEqual(2);
    });

    it('returns array of strings', () => {
      const themes = getAvailableThemes();
      for (const theme of themes) {
        expect(typeof theme).toBe('string');
      }
    });
  });

  describe('ansi proxy', () => {
    it('delegates primary to current theme', () => {
      setTheme('lemon');
      expect(ansi.primary('test')).toBe(lemonTheme.primary('test'));

      setTheme('lime');
      expect(ansi.primary('test')).toBe(limeTheme.primary('test'));
    });

    it('delegates secondary to current theme', () => {
      setTheme('lemon');
      expect(ansi.secondary('test')).toBe(lemonTheme.secondary('test'));

      setTheme('lime');
      expect(ansi.secondary('test')).toBe(limeTheme.secondary('test'));
    });

    it('delegates success to current theme', () => {
      setTheme('lemon');
      expect(ansi.success('test')).toBe(lemonTheme.success('test'));
    });

    it('delegates warning to current theme', () => {
      setTheme('lemon');
      expect(ansi.warning('test')).toBe(lemonTheme.warning('test'));
    });

    it('delegates error to current theme', () => {
      setTheme('lemon');
      expect(ansi.error('test')).toBe(lemonTheme.error('test'));
    });

    it('delegates muted to current theme', () => {
      setTheme('lemon');
      expect(ansi.muted('test')).toBe(lemonTheme.muted('test'));
    });

    it('delegates dim to current theme', () => {
      setTheme('lemon');
      expect(ansi.dim('test')).toBe(lemonTheme.dim('test'));
    });

    it('delegates bold to current theme', () => {
      setTheme('lemon');
      expect(ansi.bold('test')).toBe(lemonTheme.bold('test'));
    });

    it('delegates italic to current theme', () => {
      setTheme('lemon');
      expect(ansi.italic('test')).toBe(lemonTheme.italic('test'));
    });

    it('delegates modelineBg to current theme', () => {
      setTheme('lemon');
      expect(ansi.modelineBg('test')).toBe(lemonTheme.modelineBg('test'));
    });

    it('delegates overlayBg to current theme', () => {
      setTheme('lemon');
      expect(ansi.overlayBg('test')).toBe(lemonTheme.overlayBg('test'));
    });

    it('delegates border to current theme', () => {
      setTheme('lemon');
      expect(ansi.border('test')).toBe(lemonTheme.border('test'));
    });

    it('updates delegation when theme changes', () => {
      setTheme('lemon');
      const lemonPrimary = ansi.primary('test');

      setTheme('lime');
      const limePrimary = ansi.primary('test');

      expect(lemonPrimary).not.toBe(limePrimary);
    });
  });

  describe('getCurrentTheme', () => {
    it('returns current theme object', () => {
      const theme = getCurrentTheme();
      expect(theme).toHaveProperty('name');
      expect(theme).toHaveProperty('primary');
      expect(theme).toHaveProperty('secondary');
    });

    it('returns lemon theme by default', () => {
      const theme = getCurrentTheme();
      expect(theme.name).toBe('lemon');
    });

    it('returns lime theme after switching', () => {
      setTheme('lime');
      const theme = getCurrentTheme();
      expect(theme.name).toBe('lime');
    });
  });

  describe('Theme color functions', () => {
    it('lemonTheme functions return ANSI escape codes', () => {
      const result = lemonTheme.primary('hello');
      expect(result).toContain('\x1b[');
      expect(result).toContain('hello');
      expect(result).toContain('\x1b[0m');
    });

    it('limeTheme functions return ANSI escape codes', () => {
      const result = limeTheme.primary('hello');
      expect(result).toContain('\x1b[');
      expect(result).toContain('hello');
      expect(result).toContain('\x1b[0m');
    });

    it('lemon and lime themes have different primary colors', () => {
      const lemonResult = lemonTheme.primary('test');
      const limeResult = limeTheme.primary('test');
      expect(lemonResult).not.toBe(limeResult);
    });

    it('all theme functions handle empty strings', () => {
      expect(lemonTheme.primary('')).toContain('\x1b[');
      expect(lemonTheme.secondary('')).toContain('\x1b[');
      expect(lemonTheme.success('')).toContain('\x1b[');
      expect(lemonTheme.warning('')).toContain('\x1b[');
      expect(lemonTheme.error('')).toContain('\x1b[');
    });

    it('all theme functions handle special characters', () => {
      const input = 'hello\nworld\ttab';
      const result = lemonTheme.primary(input);
      expect(result).toContain(input);
    });
  });
});
