/**
 * Theme context — provides Ink-compatible theme colors to components.
 */

import React, { createContext, useContext, useState, useCallback } from 'react';
import { type InkTheme, getInkTheme } from '../theme.js';
import { setTheme as setAnsiTheme, getThemeName } from '../../theme.js';

interface ThemeContextValue {
  theme: InkTheme;
  themeName: string;
  setTheme: (name: string) => boolean;
}

const ThemeContext = createContext<ThemeContextValue | null>(null);

export function ThemeProvider({
  initialTheme,
  children,
}: {
  initialTheme?: string;
  children: React.ReactNode;
}) {
  const [themeName, setThemeName] = useState(initialTheme || getThemeName());
  const theme = getInkTheme(themeName);

  const setTheme = useCallback((name: string): boolean => {
    const ok = setAnsiTheme(name);
    if (ok) {
      setThemeName(name);
    }
    return ok;
  }, []);

  return (
    <ThemeContext.Provider value={{ theme, themeName, setTheme }}>
      {children}
    </ThemeContext.Provider>
  );
}

export function useTheme(): InkTheme {
  const ctx = useContext(ThemeContext);
  if (!ctx) throw new Error('useTheme must be used within ThemeProvider');
  return ctx.theme;
}

export function useThemeContext(): ThemeContextValue {
  const ctx = useContext(ThemeContext);
  if (!ctx) throw new Error('useThemeContext must be used within ThemeProvider');
  return ctx;
}
