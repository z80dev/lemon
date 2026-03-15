/**
 * Tests for the AppContext.
 */

import React from 'react';
import { describe, it, expect, vi } from 'vitest';
import { render } from 'ink-testing-library';
import { Text } from 'ink';
import { AppProvider, useApp, useStore, useConnection } from './AppContext.js';
import { createMockConnection, createTestStore } from '../test-helpers.js';

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

function StoreDisplay() {
  const store = useStore();
  const state = store.getState();
  return <Text>ready:{String(state.ready)}|cwd:{state.cwd}</Text>;
}

function ConnectionDisplay() {
  const connection = useConnection();
  // Just verify it's defined and has the expected methods
  return <Text>hasPrompt:{String(typeof connection.prompt === 'function')}</Text>;
}

function AppDisplay() {
  const app = useApp();
  return <Text>hasStore:{String(!!app.store)}|hasConnection:{String(!!app.connection)}</Text>;
}

describe('AppContext', () => {
  it('should provide store and connection', () => {
    const store = createTestStore({ cwd: '/my/dir' });
    const connection = createMockConnection();

    const { lastFrame } = render(
      <AppProvider store={store} connection={connection as any}>
        <AppDisplay />
      </AppProvider>
    );
    expect(lastFrame()).toContain('hasStore:true');
    expect(lastFrame()).toContain('hasConnection:true');
  });

  it('should provide store with correct state', () => {
    const store = createTestStore({ cwd: '/my/cwd' });
    const connection = createMockConnection();

    const { lastFrame } = render(
      <AppProvider store={store} connection={connection as any}>
        <StoreDisplay />
      </AppProvider>
    );
    expect(lastFrame()).toContain('ready:false');
    expect(lastFrame()).toContain('cwd:/my/cwd');
  });

  it('should provide store with ready state', () => {
    const store = createTestStore({ ready: true, cwd: '/ready/dir' });
    const connection = createMockConnection();

    const { lastFrame } = render(
      <AppProvider store={store} connection={connection as any}>
        <StoreDisplay />
      </AppProvider>
    );
    expect(lastFrame()).toContain('ready:true');
  });

  it('should provide connection with expected methods', () => {
    const store = createTestStore();
    const connection = createMockConnection();

    const { lastFrame } = render(
      <AppProvider store={store} connection={connection as any}>
        <ConnectionDisplay />
      </AppProvider>
    );
    expect(lastFrame()).toContain('hasPrompt:true');
  });

  it('should throw when useApp is called outside provider', () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const { lastFrame } = render(
      <ErrorBoundary>
        <AppDisplay />
      </ErrorBoundary>
    );
    expect(lastFrame()).toContain('useApp must be used within AppProvider');
    spy.mockRestore();
  });

  it('should throw when useStore is called outside provider', () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const { lastFrame } = render(
      <ErrorBoundary>
        <StoreDisplay />
      </ErrorBoundary>
    );
    expect(lastFrame()).toContain('useApp must be used within AppProvider');
    spy.mockRestore();
  });

  it('should throw when useConnection is called outside provider', () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const { lastFrame } = render(
      <ErrorBoundary>
        <ConnectionDisplay />
      </ErrorBoundary>
    );
    expect(lastFrame()).toContain('useApp must be used within AppProvider');
    spy.mockRestore();
  });
});
