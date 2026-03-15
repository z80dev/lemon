/**
 * Ink-compatible theme system.
 * Maps the existing ANSI 256 color values to Ink's color prop format.
 */

export interface InkTheme {
  name: string;
  primary: string;
  secondary: string;
  accent: string;
  success: string;
  warning: string;
  error: string;
  muted: string;
  border: string;
  modelineBg: string;
  overlayBg: string;
}

const lemonInkTheme: InkTheme = {
  name: 'lemon',
  primary: 'ansi256(220)',     // Lemon yellow
  secondary: 'ansi256(228)',   // Pale lemon
  accent: 'ansi256(208)',      // Warm orange
  success: 'ansi256(114)',     // Citrus green
  warning: 'ansi256(214)',     // Orange
  error: 'ansi256(203)',       // Red
  muted: 'ansi256(243)',       // Gray
  border: 'ansi256(240)',      // Darker gray
  modelineBg: 'ansi256(58)',   // Dark olive bg
  overlayBg: 'ansi256(236)',   // Dark gray bg
};

const limeInkTheme: InkTheme = {
  name: 'lime',
  primary: 'ansi256(118)',
  secondary: 'ansi256(157)',
  accent: 'ansi256(154)',
  success: 'ansi256(114)',
  warning: 'ansi256(214)',
  error: 'ansi256(203)',
  muted: 'ansi256(243)',
  border: 'ansi256(240)',
  modelineBg: 'ansi256(22)',
  overlayBg: 'ansi256(22)',
};

const midnightInkTheme: InkTheme = {
  name: 'midnight',
  primary: 'ansi256(141)',
  secondary: 'ansi256(183)',
  accent: 'ansi256(81)',
  success: 'ansi256(114)',
  warning: 'ansi256(221)',
  error: 'ansi256(204)',
  muted: 'ansi256(245)',
  border: 'ansi256(60)',
  modelineBg: 'ansi256(17)',
  overlayBg: 'ansi256(17)',
};

const roseInkTheme: InkTheme = {
  name: 'rose',
  primary: 'ansi256(211)',
  secondary: 'ansi256(224)',
  accent: 'ansi256(205)',
  success: 'ansi256(150)',
  warning: 'ansi256(222)',
  error: 'ansi256(196)',
  muted: 'ansi256(244)',
  border: 'ansi256(132)',
  modelineBg: 'ansi256(52)',
  overlayBg: 'ansi256(52)',
};

const oceanInkTheme: InkTheme = {
  name: 'ocean',
  primary: 'ansi256(38)',
  secondary: 'ansi256(116)',
  accent: 'ansi256(51)',
  success: 'ansi256(114)',
  warning: 'ansi256(215)',
  error: 'ansi256(203)',
  muted: 'ansi256(245)',
  border: 'ansi256(30)',
  modelineBg: 'ansi256(23)',
  overlayBg: 'ansi256(23)',
};

const contrastInkTheme: InkTheme = {
  name: 'contrast',
  primary: 'ansi256(15)',       // Bright white
  secondary: 'ansi256(14)',     // Bright cyan
  accent: 'ansi256(11)',        // Bright yellow
  success: 'ansi256(10)',       // Bright green
  warning: 'ansi256(11)',       // Bright yellow
  error: 'ansi256(9)',          // Bright red
  muted: 'ansi256(250)',        // Light gray for better visibility
  border: 'ansi256(248)',       // Light gray border
  modelineBg: 'ansi256(234)',   // Very dark bg
  overlayBg: 'ansi256(234)',    // Very dark bg
};

export const inkThemes: Record<string, InkTheme> = {
  lemon: lemonInkTheme,
  lime: limeInkTheme,
  midnight: midnightInkTheme,
  rose: roseInkTheme,
  ocean: oceanInkTheme,
  contrast: contrastInkTheme,
};

export function getInkTheme(name: string): InkTheme {
  return inkThemes[name] || lemonInkTheme;
}
