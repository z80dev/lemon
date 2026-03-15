/**
 * Tests for the WidgetPanel component.
 */

import React from 'react';
import { describe, it, expect } from 'vitest';
import { renderWithContext, createTestStore } from '../test-helpers.js';
import { WidgetPanel } from './WidgetPanel.js';

describe('WidgetPanel', () => {
  it('should render nothing when no widgets', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    const { lastFrame } = renderWithContext(<WidgetPanel />, { store });
    expect(lastFrame()).toBe('');
  });

  it('should render widget with key and content', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.setWidget('status', ['Running: 5 tests', 'Passed: 5'], {});
    const { lastFrame } = renderWithContext(<WidgetPanel />, { store });
    const frame = lastFrame();
    expect(frame).toContain('[status]');
    expect(frame).toContain('Running: 5 tests');
    expect(frame).toContain('Passed: 5');
  });

  it('should render multiple widgets', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.setWidget('widget1', ['Content 1'], {});
    store.setWidget('widget2', ['Content 2'], {});
    const { lastFrame } = renderWithContext(<WidgetPanel />, { store });
    const frame = lastFrame();
    expect(frame).toContain('[widget1]');
    expect(frame).toContain('Content 1');
    expect(frame).toContain('[widget2]');
    expect(frame).toContain('Content 2');
  });

  it('should clear widget when content is set to null', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.setWidget('test', ['some content'], {});
    store.setWidget('test', null, {});
    const { lastFrame } = renderWithContext(<WidgetPanel />, { store });
    expect(lastFrame()).toBe('');
  });
});
