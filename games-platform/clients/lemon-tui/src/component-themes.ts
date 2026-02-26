/**
 * Component theme objects for pi-tui components.
 * Extracted from index.ts to improve modularity.
 */

import type {
  EditorTheme,
  MarkdownTheme,
  SelectListTheme,
  SettingsListTheme,
  ImageTheme,
} from '@mariozechner/pi-tui';
import { ansi } from './theme.js';

// Theme objects use wrapper functions to ensure they always use the current theme
export const selectListTheme: SelectListTheme = {
  selectedPrefix: (s: string) => ansi.primary(s),
  selectedText: (s: string) => ansi.bold(s),
  description: (s: string) => ansi.muted(s),
  scrollInfo: (s: string) => ansi.muted(s),
  noMatch: (s: string) => ansi.muted(s),
};

export const markdownTheme: MarkdownTheme = {
  heading: (s: string) => ansi.bold(ansi.primary(s)),
  link: (s: string) => ansi.primary(s),
  linkUrl: (s: string) => ansi.muted(s),
  code: (s: string) => ansi.accent(s),
  codeBlock: (s: string) => ansi.success(s),
  codeBlockBorder: (s: string) => ansi.muted(s),
  quote: (s: string) => ansi.italic(s),
  quoteBorder: (s: string) => ansi.muted(s),
  hr: (s: string) => ansi.muted(s),
  listBullet: (s: string) => ansi.primary(s),
  bold: (s: string) => ansi.bold(s),
  italic: (s: string) => ansi.italic(s),
  strikethrough: (s: string) => `\x1b[9m${s}\x1b[0m`,
  underline: (s: string) => `\x1b[4m${s}\x1b[0m`,
};

export const editorTheme: EditorTheme = {
  borderColor: (s: string) => ansi.primary(s),
  selectList: selectListTheme,
};

// Note: settingsListTheme is created dynamically to support theme switching
export function getSettingsListTheme(): SettingsListTheme {
  return {
    label: (text: string, selected: boolean) => selected ? ansi.bold(ansi.primary(text)) : text,
    value: (text: string, selected: boolean) => selected ? ansi.secondary(text) : ansi.muted(text),
    description: (s: string) => ansi.muted(s),
    cursor: ansi.primary('>'),
    hint: (s: string) => ansi.muted(s),
  };
}

export const imageTheme: ImageTheme = {
  fallbackColor: (s: string) => ansi.muted(s),
};
