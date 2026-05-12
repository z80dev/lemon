import React from 'react';
import { describe, expect, it, vi } from 'vitest';
import { AppLayout } from './AppLayout.js';
import { createMockConnection, createTestStore, renderWithContext } from './test-helpers.js';

function delay(ms = 20) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

describe('AppLayout', () => {
  it('aborts a busy run on double Escape', async () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.handleEvent({ type: 'agent_start' }, 'session-1');
    const connection = createMockConnection();

    const { stdin, unmount } = renderWithContext(
      <AppLayout onStop={vi.fn()} />,
      { store, connection }
    );

    await delay();
    stdin.write('\x1B');
    await delay();
    expect(connection.abort).not.toHaveBeenCalled();

    stdin.write('\x1B');
    await delay();
    expect(connection.abort).toHaveBeenCalledOnce();

    unmount();
  });
});
