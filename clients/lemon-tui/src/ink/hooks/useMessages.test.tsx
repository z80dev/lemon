/**
 * Tests for useMessages and useStreamingMessage hooks.
 */

import React from 'react';
import { describe, it, expect } from 'vitest';
import { Text } from 'ink';
import { renderWithContext, createTestStore } from '../test-helpers.js';
import { useMessages, useStreamingMessage } from './useMessages.js';

function MessagesDisplay() {
  const messages = useMessages();
  return <Text>count:{messages.length}</Text>;
}

function StreamingDisplay() {
  const streaming = useStreamingMessage();
  return <Text>streaming:{String(streaming)}</Text>;
}

describe('useMessages', () => {
  it('returns empty array initially', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    const { lastFrame } = renderWithContext(<MessagesDisplay />, { store });

    expect(lastFrame()).toContain('count:0');
  });

  it('returns messages from state after message event', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    // Add a user message via message_start event
    store.handleEvent(
      {
        type: 'message_start',
        data: [
          {
            __struct__: 'Elixir.Ai.Types.UserMessage',
            role: 'user',
            content: 'hello',
            timestamp: Date.now(),
          },
        ],
      },
      'session-1'
    );
    const { lastFrame } = renderWithContext(<MessagesDisplay />, { store });

    expect(lastFrame()).toContain('count:1');
  });
});

describe('useStreamingMessage', () => {
  it('returns null initially', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    const { lastFrame } = renderWithContext(<StreamingDisplay />, { store });

    expect(lastFrame()).toContain('streaming:null');
  });
});
