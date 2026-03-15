/**
 * Tests for the NotificationHistoryOverlay component.
 */

import React from 'react';
import { describe, it, expect, vi } from 'vitest';
import { renderWithContext, createTestStore } from '../test-helpers.js';
import { NotificationHistoryOverlay } from './NotificationHistoryOverlay.js';

function delay(ms = 5) { return new Promise<void>(r => setTimeout(r, ms)); }

describe('NotificationHistoryOverlay', () => {
  it('should show empty state when no notifications', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    const { lastFrame } = renderWithContext(
      <NotificationHistoryOverlay onClose={vi.fn()} />,
      { store }
    );
    expect(lastFrame()).toContain('No notifications yet');
  });

  it('should show notification entries', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.addNotification('Build succeeded', 'success');
    store.addNotification('Something went wrong', 'error');
    const { lastFrame } = renderWithContext(
      <NotificationHistoryOverlay onClose={vi.fn()} />,
      { store }
    );
    const frame = lastFrame();
    expect(frame).toContain('Build succeeded');
    expect(frame).toContain('Something went wrong');
  });

  it('should close on Escape', async () => {
    const onClose = vi.fn();
    const store = createTestStore({ ready: true, cwd: '/test' });
    const { stdin } = renderWithContext(
      <NotificationHistoryOverlay onClose={onClose} />,
      { store }
    );
    await delay();
    stdin.write('\x1B');
    await delay();
    expect(onClose).toHaveBeenCalled();
  });

  it('should close on q', async () => {
    const onClose = vi.fn();
    const store = createTestStore({ ready: true, cwd: '/test' });
    const { stdin } = renderWithContext(
      <NotificationHistoryOverlay onClose={onClose} />,
      { store }
    );
    await delay();
    stdin.write('q');
    await delay();
    expect(onClose).toHaveBeenCalled();
  });

  it('should clear history on c', async () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.addNotification('test notification', 'info');
    const { stdin, lastFrame } = renderWithContext(
      <NotificationHistoryOverlay onClose={vi.fn()} />,
      { store }
    );
    expect(lastFrame()).toContain('test notification');
    await delay();
    stdin.write('c');
    await delay(20);
    expect(lastFrame()).toContain('No notifications yet');
  });

  it('should show title', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    const { lastFrame } = renderWithContext(
      <NotificationHistoryOverlay onClose={vi.fn()} />,
      { store }
    );
    expect(lastFrame()).toContain('Notifications');
  });
});
