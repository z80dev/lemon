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
  accent: (s: string) => string;
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
  accent: (s: string) => `\x1b[38;5;208m${s}\x1b[0m`,     // Warm orange accent (distinct from warning 214)
  success: (s: string) => `\x1b[38;5;114m${s}\x1b[0m`,    // Citrus green
  warning: (s: string) => `\x1b[38;5;214m${s}\x1b[0m`,    // Orange
  error: (s: string) => `\x1b[38;5;203m${s}\x1b[0m`,      // Red
  muted: (s: string) => `\x1b[38;5;243m${s}\x1b[0m`,      // Gray
  dim: (s: string) => `\x1b[2m${s}\x1b[0m`,
  bold: (s: string) => `\x1b[1m${s}\x1b[0m`,
  italic: (s: string) => `\x1b[3m${s}\x1b[0m`,
  modelineBg: (s: string) => `\x1b[48;5;58m${s}\x1b[0m`,  // Dark olive/yellow bg
  overlayBg: (s: string) => `\x1b[48;5;236m${s}\x1b[0m`,  // Dark gray bg for overlays
  border: (s: string) => `\x1b[38;5;240m${s}\x1b[0m`,     // Darker gray border (distinct from muted 243)
};

/**
 * The lime theme - fresh green tones.
 */
export const limeTheme: Theme = {
  name: 'lime',
  primary: (s: string) => `\x1b[38;5;118m${s}\x1b[0m`,    // Bright green
  secondary: (s: string) => `\x1b[38;5;157m${s}\x1b[0m`,  // Pale green
  accent: (s: string) => `\x1b[38;5;154m${s}\x1b[0m`,     // Chartreuse accent
  success: (s: string) => `\x1b[38;5;114m${s}\x1b[0m`,    // Citrus green
  warning: (s: string) => `\x1b[38;5;214m${s}\x1b[0m`,    // Orange
  error: (s: string) => `\x1b[38;5;203m${s}\x1b[0m`,      // Red
  muted: (s: string) => `\x1b[38;5;243m${s}\x1b[0m`,      // Gray
  dim: (s: string) => `\x1b[2m${s}\x1b[0m`,
  bold: (s: string) => `\x1b[1m${s}\x1b[0m`,
  italic: (s: string) => `\x1b[3m${s}\x1b[0m`,
  modelineBg: (s: string) => `\x1b[48;5;22m${s}\x1b[0m`,  // Dark green bg
  overlayBg: (s: string) => `\x1b[48;5;22m${s}\x1b[0m`,   // Dark green bg for overlays
  border: (s: string) => `\x1b[38;5;240m${s}\x1b[0m`,     // Darker gray border (distinct from muted)
};

/**
 * The midnight theme - deep indigo/purple tones.
 */
export const midnightTheme: Theme = {
  name: 'midnight',
  primary: (s: string) => `\x1b[38;5;141m${s}\x1b[0m`,    // Soft purple/indigo
  secondary: (s: string) => `\x1b[38;5;183m${s}\x1b[0m`,  // Lavender
  accent: (s: string) => `\x1b[38;5;81m${s}\x1b[0m`,      // Bright cyan accent
  success: (s: string) => `\x1b[38;5;114m${s}\x1b[0m`,    // Green
  warning: (s: string) => `\x1b[38;5;221m${s}\x1b[0m`,    // Gold
  error: (s: string) => `\x1b[38;5;204m${s}\x1b[0m`,      // Pink-red
  muted: (s: string) => `\x1b[38;5;245m${s}\x1b[0m`,      // Cool gray
  dim: (s: string) => `\x1b[2m${s}\x1b[0m`,
  bold: (s: string) => `\x1b[1m${s}\x1b[0m`,
  italic: (s: string) => `\x1b[3m${s}\x1b[0m`,
  modelineBg: (s: string) => `\x1b[48;5;17m${s}\x1b[0m`,  // Deep navy bg
  overlayBg: (s: string) => `\x1b[48;5;17m${s}\x1b[0m`,   // Deep navy bg for overlays
  border: (s: string) => `\x1b[38;5;60m${s}\x1b[0m`,      // Muted purple border
};

/**
 * The rose theme - soft pink/red tones.
 */
export const roseTheme: Theme = {
  name: 'rose',
  primary: (s: string) => `\x1b[38;5;211m${s}\x1b[0m`,    // Soft pink
  secondary: (s: string) => `\x1b[38;5;224m${s}\x1b[0m`,  // Pale pink
  accent: (s: string) => `\x1b[38;5;205m${s}\x1b[0m`,     // Hot pink/magenta accent
  success: (s: string) => `\x1b[38;5;150m${s}\x1b[0m`,    // Soft green
  warning: (s: string) => `\x1b[38;5;222m${s}\x1b[0m`,    // Warm gold
  error: (s: string) => `\x1b[38;5;196m${s}\x1b[0m`,      // Bright red
  muted: (s: string) => `\x1b[38;5;244m${s}\x1b[0m`,      // Warm gray
  dim: (s: string) => `\x1b[2m${s}\x1b[0m`,
  bold: (s: string) => `\x1b[1m${s}\x1b[0m`,
  italic: (s: string) => `\x1b[3m${s}\x1b[0m`,
  modelineBg: (s: string) => `\x1b[48;5;52m${s}\x1b[0m`,  // Dark rose bg
  overlayBg: (s: string) => `\x1b[48;5;52m${s}\x1b[0m`,   // Dark rose bg for overlays
  border: (s: string) => `\x1b[38;5;132m${s}\x1b[0m`,     // Muted rose border
};

/**
 * The ocean theme - teal/cyan tones.
 */
export const oceanTheme: Theme = {
  name: 'ocean',
  primary: (s: string) => `\x1b[38;5;38m${s}\x1b[0m`,     // Deep teal
  secondary: (s: string) => `\x1b[38;5;116m${s}\x1b[0m`,  // Pale aqua
  accent: (s: string) => `\x1b[38;5;51m${s}\x1b[0m`,      // Bright cyan accent
  success: (s: string) => `\x1b[38;5;114m${s}\x1b[0m`,    // Green
  warning: (s: string) => `\x1b[38;5;215m${s}\x1b[0m`,    // Sandy orange
  error: (s: string) => `\x1b[38;5;203m${s}\x1b[0m`,      // Coral red
  muted: (s: string) => `\x1b[38;5;245m${s}\x1b[0m`,      // Blue-gray
  dim: (s: string) => `\x1b[2m${s}\x1b[0m`,
  bold: (s: string) => `\x1b[1m${s}\x1b[0m`,
  italic: (s: string) => `\x1b[3m${s}\x1b[0m`,
  modelineBg: (s: string) => `\x1b[48;5;23m${s}\x1b[0m`,  // Deep ocean bg
  overlayBg: (s: string) => `\x1b[48;5;23m${s}\x1b[0m`,   // Deep ocean bg for overlays
  border: (s: string) => `\x1b[38;5;30m${s}\x1b[0m`,      // Muted teal border
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
  midnight: midnightTheme,
  rose: roseTheme,
  ocean: oceanTheme,
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
  get accent() { return currentTheme.accent; },
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
  const y = ansi.primary;      // Primary for lemon body
  const g = ansi.success;      // Green for leaf
  const a = ansi.accent;       // Accent for face features

  return [
    `       ${g('▄██▄')}`,
    `      ${y('▄')}${g('████')}${y('▄')}`,
    `     ${y('████████')}`,
    `    ${y('██')} ${a('◠')}  ${a('◠')} ${y('██')}`,
    `    ${y('██')}  ${a('‿')}   ${y('██')}`,
    `     ${y('████████')}`,
    `      ${y('▀████▀')}`,
  ].join('\n');
}
