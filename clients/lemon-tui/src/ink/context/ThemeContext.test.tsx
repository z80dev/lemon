/**
 * Tests for the ThemeContext.
 */

import React from 'react';
import { describe, it, expect, vi } from 'vitest';
import { render } from 'ink-testing-library';
import { Text, Box } from 'ink';
import { ThemeProvider, useTheme, useThemeContext } from './ThemeContext.js';

class ErrorBoundary extends React.Component<
  { children: React.ReactNode },
  { error: string | null }
> {
  state = { error: null as string | null };
  static getDerivedStateFromError(error: Error) {
    return { error: error.message };
  }
  render() {
    if (this.state.error) return <Text>Error: {this.state.error}</Text>;
    return this.props.children;
  }
}

function ThemeDisplay() {
  const theme = useTheme();
  return <Text>theme:{theme.name}|primary:{theme.primary}</Text>;
}

function ThemeSwitcher() {
  const { themeName, setTheme } = useThemeContext();
  return (
    <Box flexDirection="column">
      <Text>current:{themeName}</Text>
    </Box>
  );
}

describe('ThemeContext', () => {
  it('should provide default lemon theme', () => {
    const { lastFrame } = render(
      <ThemeProvider>
        <ThemeDisplay />
      </ThemeProvider>
    );
    expect(lastFrame()).toContain('theme:lemon');
    expect(lastFrame()).toContain('primary:ansi256(220)');
  });

  it('should provide specified initial theme', () => {
    const { lastFrame } = render(
      <ThemeProvider initialTheme="midnight">
        <ThemeDisplay />
      </ThemeProvider>
    );
    expect(lastFrame()).toContain('theme:midnight');
    expect(lastFrame()).toContain('primary:ansi256(141)');
  });

  it('should provide ocean theme', () => {
    const { lastFrame } = render(
      <ThemeProvider initialTheme="ocean">
        <ThemeDisplay />
      </ThemeProvider>
    );
    expect(lastFrame()).toContain('theme:ocean');
    expect(lastFrame()).toContain('primary:ansi256(38)');
  });

  it('should provide rose theme', () => {
    const { lastFrame } = render(
      <ThemeProvider initialTheme="rose">
        <ThemeDisplay />
      </ThemeProvider>
    );
    expect(lastFrame()).toContain('theme:rose');
  });

  it('should provide lime theme', () => {
    const { lastFrame } = render(
      <ThemeProvider initialTheme="lime">
        <ThemeDisplay />
      </ThemeProvider>
    );
    expect(lastFrame()).toContain('theme:lime');
  });

  it('should provide theme name through useThemeContext', () => {
    const { lastFrame } = render(
      <ThemeProvider initialTheme="midnight">
        <ThemeSwitcher />
      </ThemeProvider>
    );
    expect(lastFrame()).toContain('current:midnight');
  });

  it('should throw when useTheme is called outside provider', () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const { lastFrame } = render(
      <ErrorBoundary>
        <ThemeDisplay />
      </ErrorBoundary>
    );
    expect(lastFrame()).toContain('useTheme must be used within ThemeProvider');
    spy.mockRestore();
  });

  it('should throw when useThemeContext is called outside provider', () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const { lastFrame } = render(
      <ErrorBoundary>
        <ThemeSwitcher />
      </ErrorBoundary>
    );
    expect(lastFrame()).toContain('useThemeContext must be used within ThemeProvider');
    spy.mockRestore();
  });
});
