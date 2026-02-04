/**
 * Theme system for Lemon TUI.
 * Provides theming support with multiple color schemes.
 */

// ============================================================================
// Theme Interface
// ============================================================================

/**
 * Theme interface defining all color functions used throughout the TUI.
 */
export interface Theme {
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

// ============================================================================
// Theme Definitions
// ============================================================================

/**
 * The lemon theme - warm yellow tones with citrus accents.
 */
export const lemonTheme: Theme = {
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
export const limeTheme: Theme = {
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

// ============================================================================
// Theme Registry
// ============================================================================

/**
 * Registry of available themes.
 */
export const themes: Record<string, Theme> = {
  lemon: lemonTheme,
  lime: limeTheme,
};

/**
 * The currently active theme.
 */
let currentTheme: Theme = themes.lemon;

// ============================================================================
// Theme Functions
// ============================================================================

/**
 * Switch to a different theme by name.
 * @param name The name of the theme to switch to
 * @returns true if the theme was found and switched, false otherwise
 */
export function setTheme(name: string): boolean {
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
export function getThemeName(): string {
  return currentTheme.name;
}

/**
 * Get the list of available theme names.
 */
export function getAvailableThemes(): string[] {
  return Object.keys(themes);
}

/**
 * Get the current theme object.
 * Useful for testing or advanced customization.
 */
export function getCurrentTheme(): Theme {
  return currentTheme;
}

// ============================================================================
// ANSI Proxy
// ============================================================================

/**
 * Proxy object that delegates to the current theme.
 * This allows existing code to use `ansi.primary(...)` without changes.
 */
export const ansi = {
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
// Lemon Mascot ASCII Art
// ============================================================================

/**
 * Cute lemon mascot for the welcome screen.
 * Uses colorful block characters with theme colors.
 */
export function getLemonArt(): string {
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
