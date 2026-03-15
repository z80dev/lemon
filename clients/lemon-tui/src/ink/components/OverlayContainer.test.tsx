/**
 * Tests for the OverlayContainer component.
 */

import React from 'react';
import { describe, it, expect } from 'vitest';
import { render } from 'ink-testing-library';
import { Text } from 'ink';
import { ThemeProvider } from '../context/ThemeContext.js';
import { OverlayContainer } from './OverlayContainer.js';

describe('OverlayContainer', () => {
  it('should render title and children', () => {
    const { lastFrame } = render(
      <ThemeProvider initialTheme="lemon">
        <OverlayContainer title="My Overlay">
          <Text>Child content here</Text>
        </OverlayContainer>
      </ThemeProvider>
    );
    const frame = lastFrame();
    expect(frame).toContain('My Overlay');
    expect(frame).toContain('Child content here');
  });

  it('should render with border', () => {
    const { lastFrame } = render(
      <ThemeProvider initialTheme="lemon">
        <OverlayContainer title="Bordered">
          <Text>Content</Text>
        </OverlayContainer>
      </ThemeProvider>
    );
    const frame = lastFrame();
    // Round border style characters
    expect(frame).toContain('\u256D'); // top-left round
    expect(frame).toContain('\u256E'); // top-right round
  });

  it('should render multiple children', () => {
    const { lastFrame } = render(
      <ThemeProvider initialTheme="lemon">
        <OverlayContainer title="Multi">
          <Text>Line 1</Text>
          <Text>Line 2</Text>
        </OverlayContainer>
      </ThemeProvider>
    );
    const frame = lastFrame();
    expect(frame).toContain('Line 1');
    expect(frame).toContain('Line 2');
  });
});
