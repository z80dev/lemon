/**
 * Tests for the MessageSeparator component.
 */

import React from 'react';
import { describe, it, expect, vi } from 'vitest';
import { render } from 'ink-testing-library';
import { ThemeProvider } from '../context/ThemeContext.js';
import { MessageSeparator } from './MessageSeparator.js';

function renderWithTheme(ui: React.ReactElement) {
  return render(<ThemeProvider initialTheme="lemon">{ui}</ThemeProvider>);
}

describe('MessageSeparator', () => {
  it('should render separator line with ─ characters', () => {
    const { lastFrame } = renderWithTheme(<MessageSeparator />);
    const frame = lastFrame();
    expect(frame).toContain('─');
  });
});
