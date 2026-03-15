/**
 * Tests for the ErrorBoundary component.
 */

import React from 'react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render } from 'ink-testing-library';
import { Text } from 'ink';
import { ErrorBoundary } from './ErrorBoundary.js';

// Suppress React error boundary console output during tests
beforeEach(() => {
  vi.spyOn(console, 'error').mockImplementation(() => {});
  vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
});

function ThrowingComponent({ shouldThrow }: { shouldThrow: boolean }) {
  if (shouldThrow) {
    throw new Error('Test render error');
  }
  return <Text>No error</Text>;
}

describe('ErrorBoundary', () => {
  it('should render children when no error', () => {
    const { lastFrame } = render(
      <ErrorBoundary>
        <Text>Child content</Text>
      </ErrorBoundary>
    );
    expect(lastFrame()).toContain('Child content');
  });

  it('should catch render errors and show fallback', () => {
    const { lastFrame } = render(
      <ErrorBoundary>
        <ThrowingComponent shouldThrow={true} />
      </ErrorBoundary>
    );
    expect(lastFrame()).toContain('component encountered an error');
    expect(lastFrame()).toContain('Test render error');
  });

  it('should show custom fallback message', () => {
    const { lastFrame } = render(
      <ErrorBoundary fallbackMessage="Custom error message">
        <ThrowingComponent shouldThrow={true} />
      </ErrorBoundary>
    );
    expect(lastFrame()).toContain('Custom error message');
  });

  it('should show recovery hint', () => {
    const { lastFrame } = render(
      <ErrorBoundary>
        <ThrowingComponent shouldThrow={true} />
      </ErrorBoundary>
    );
    expect(lastFrame()).toContain('rest of the UI should still work');
  });
});
