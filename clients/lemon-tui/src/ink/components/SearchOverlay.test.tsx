/**
 * Tests for the SearchOverlay component.
 */

import React from 'react';
import { describe, it, expect, vi } from 'vitest';
import { renderWithContext, createTestStore } from '../test-helpers.js';
import { SearchOverlay } from './SearchOverlay.js';

describe('SearchOverlay', () => {
  it('should render search title', () => {
    const store = createTestStore({ ready: true });
    const onClose = vi.fn();
    const { lastFrame } = renderWithContext(
      <SearchOverlay onClose={onClose} />,
      { store }
    );
    expect(lastFrame()).toContain('Search Messages');
  });

  it('should show initial prompt', () => {
    const store = createTestStore({ ready: true });
    const onClose = vi.fn();
    const { lastFrame } = renderWithContext(
      <SearchOverlay onClose={onClose} />,
      { store }
    );
    expect(lastFrame()).toContain('Type to search');
  });

  it('should render with initial query', () => {
    const store = createTestStore({ ready: true });
    const onClose = vi.fn();
    const { lastFrame } = renderWithContext(
      <SearchOverlay initialQuery="hello" onClose={onClose} />,
      { store }
    );
    expect(lastFrame()).toContain('hello');
  });

  it('should show no matches message when query has no results', () => {
    const store = createTestStore({ ready: true });
    const onClose = vi.fn();
    const { lastFrame } = renderWithContext(
      <SearchOverlay initialQuery="zzz_nonexistent_zzz" onClose={onClose} />,
      { store }
    );
    expect(lastFrame()).toContain('No matches');
  });

  it('should show escape hint', () => {
    const store = createTestStore({ ready: true });
    const onClose = vi.fn();
    const { lastFrame } = renderWithContext(
      <SearchOverlay onClose={onClose} />,
      { store }
    );
    expect(lastFrame()).toContain('Escape');
  });
});
