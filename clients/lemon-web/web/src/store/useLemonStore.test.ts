import { describe, it, expect, beforeEach } from 'vitest';
import { useLemonStore, getMessageKey, type MessageWithMeta } from './useLemonStore';
import type { UserMessage, AssistantMessage, ToolResultMessage, EventMessage } from '@lemon-web/shared';

/**
 * Test helpers for creating message fixtures
 */
function createUserMessage(overrides: Partial<UserMessage> = {}): UserMessage {
  return {
    __struct__: 'Elixir.Ai.Types.UserMessage',
    role: 'user',
    content: 'test message',
    timestamp: Date.now(),
    ...overrides,
  };
}

function createAssistantMessage(overrides: Partial<AssistantMessage> = {}): AssistantMessage {
  return {
    __struct__: 'Elixir.Ai.Types.AssistantMessage',
    role: 'assistant',
    content: [],
    provider: 'test',
    model: 'test-model',
    api: 'messages',
    stop_reason: 'stop',
    error_message: null,
    timestamp: Date.now(),
    ...overrides,
  };
}

function createToolResultMessage(overrides: Partial<ToolResultMessage> = {}): ToolResultMessage {
  return {
    __struct__: 'Elixir.Ai.Types.ToolResultMessage',
    role: 'tool_result',
    tool_call_id: 'tool-123',
    tool_name: 'test_tool',
    content: [],
    is_error: false,
    timestamp: Date.now(),
    ...overrides,
  };
}

function wrapWithMeta(
  msg: UserMessage | AssistantMessage | ToolResultMessage,
  eventSeq?: number,
  insertionIndex: number = 0
): MessageWithMeta {
  return {
    ...msg,
    _event_seq: eventSeq,
    _insertionIndex: insertionIndex,
  };
}

describe('useLemonStore message keying and ordering', () => {
  beforeEach(() => {
    // Reset the store state before each test
    useLemonStore.setState({
      messagesBySession: {},
      _insertionCounters: {},
    });
  });

  describe('getMessageKey()', () => {
    it('generates key for user message without event_seq', () => {
      const timestamp = 1700000000000;
      const msg = wrapWithMeta(createUserMessage({ timestamp }), undefined, 0);

      const key = getMessageKey(msg);

      expect(key).toBe(`user-${timestamp}-0`);
    });

    it('generates key for user message with event_seq', () => {
      const timestamp = 1700000000000;
      const msg = wrapWithMeta(createUserMessage({ timestamp }), 5, 0);

      const key = getMessageKey(msg);

      expect(key).toBe(`5-user-${timestamp}-0`);
    });

    it('generates key for assistant message without event_seq', () => {
      const timestamp = 1700000000001;
      const msg = wrapWithMeta(createAssistantMessage({ timestamp }), undefined, 1);

      const key = getMessageKey(msg);

      expect(key).toBe(`assistant-${timestamp}-1`);
    });

    it('generates key for assistant message with event_seq', () => {
      const timestamp = 1700000000001;
      const msg = wrapWithMeta(createAssistantMessage({ timestamp }), 10, 1);

      const key = getMessageKey(msg);

      expect(key).toBe(`10-assistant-${timestamp}-1`);
    });

    it('generates key for tool_result message using tool_call_id', () => {
      const msg = wrapWithMeta(
        createToolResultMessage({ tool_call_id: 'call-abc123' }),
        undefined,
        2
      );

      const key = getMessageKey(msg);

      expect(key).toBe('tool-call-abc123-2');
    });

    it('generates key for tool_result message with event_seq', () => {
      const msg = wrapWithMeta(
        createToolResultMessage({ tool_call_id: 'call-xyz789' }),
        15,
        3
      );

      const key = getMessageKey(msg);

      expect(key).toBe('15-tool-call-xyz789-3');
    });

    it('generates unique keys for messages with same timestamp but different insertion index', () => {
      const timestamp = 1700000000000;
      const msg1 = wrapWithMeta(createUserMessage({ timestamp }), undefined, 0);
      const msg2 = wrapWithMeta(createUserMessage({ timestamp }), undefined, 1);

      const key1 = getMessageKey(msg1);
      const key2 = getMessageKey(msg2);

      expect(key1).not.toBe(key2);
      expect(key1).toBe(`user-${timestamp}-0`);
      expect(key2).toBe(`user-${timestamp}-1`);
    });

    it('generates unique keys for different message types', () => {
      const timestamp = 1700000000000;
      const userMsg = wrapWithMeta(createUserMessage({ timestamp }), 1, 0);
      const assistantMsg = wrapWithMeta(createAssistantMessage({ timestamp }), 1, 1);
      const toolMsg = wrapWithMeta(createToolResultMessage({ tool_call_id: 'call-123' }), 1, 2);

      const userKey = getMessageKey(userMsg);
      const assistantKey = getMessageKey(assistantMsg);
      const toolKey = getMessageKey(toolMsg);

      expect(userKey).not.toBe(assistantKey);
      expect(userKey).not.toBe(toolKey);
      expect(assistantKey).not.toBe(toolKey);
    });
  });

  describe('message sorting with event_seq', () => {
    it('sorts messages by event_seq when both have it', () => {
      const sessionId = 'test-session';
      const store = useLemonStore.getState();

      // Apply messages out of order
      store.applyServerMessage({
        type: 'event',
        session_id: sessionId,
        event_seq: 2,
        event: {
          type: 'message_start',
          data: [createUserMessage({ content: 'second' })],
        },
      } as EventMessage);

      store.applyServerMessage({
        type: 'event',
        session_id: sessionId,
        event_seq: 1,
        event: {
          type: 'message_start',
          data: [createAssistantMessage({ content: [{ __struct__: 'Elixir.Ai.Types.TextContent', type: 'text', text: 'first' }] })],
        },
      } as EventMessage);

      const messages = useLemonStore.getState().messagesBySession[sessionId];

      expect(messages).toHaveLength(2);
      expect(messages[0].role).toBe('assistant');
      expect(messages[0]._event_seq).toBe(1);
      expect(messages[1].role).toBe('user');
      expect(messages[1]._event_seq).toBe(2);
    });

    it('messages without event_seq come before messages with event_seq', () => {
      const sessionId = 'test-session';
      const timestamp = Date.now();
      const store = useLemonStore.getState();

      // Message with event_seq
      store.applyServerMessage({
        type: 'event',
        session_id: sessionId,
        event_seq: 5,
        event: {
          type: 'message_start',
          data: [createUserMessage({ content: 'with seq', timestamp })],
        },
      } as EventMessage);

      // Message without event_seq (older protocol)
      store.applyServerMessage({
        type: 'event',
        session_id: sessionId,
        event: {
          type: 'message_start',
          data: [createAssistantMessage({ content: [{ __struct__: 'Elixir.Ai.Types.TextContent', type: 'text', text: 'no seq' }], timestamp: timestamp + 1 })],
        },
      } as unknown as EventMessage);

      const messages = useLemonStore.getState().messagesBySession[sessionId];

      expect(messages).toHaveLength(2);
      // Message without event_seq should come first
      expect(messages[0]._event_seq).toBeUndefined();
      expect(messages[1]._event_seq).toBe(5);
    });
  });

  describe('fallback sorting to timestamp + insertion index', () => {
    it('sorts by timestamp when event_seq is missing', () => {
      const sessionId = 'test-session';
      const store = useLemonStore.getState();

      // Apply messages with different timestamps, no event_seq
      store.applyServerMessage({
        type: 'event',
        session_id: sessionId,
        event: {
          type: 'message_start',
          data: [createUserMessage({ content: 'later', timestamp: 1700000002000 })],
        },
      } as unknown as EventMessage);

      store.applyServerMessage({
        type: 'event',
        session_id: sessionId,
        event: {
          type: 'message_start',
          data: [createAssistantMessage({ timestamp: 1700000001000 })],
        },
      } as unknown as EventMessage);

      const messages = useLemonStore.getState().messagesBySession[sessionId];

      expect(messages).toHaveLength(2);
      expect(messages[0].timestamp).toBe(1700000001000);
      expect(messages[1].timestamp).toBe(1700000002000);
    });

    it('uses insertion index as tiebreaker for same timestamp', () => {
      const sessionId = 'test-session';
      const sameTimestamp = 1700000000000;
      const store = useLemonStore.getState();

      // Apply multiple messages with same timestamp
      store.applyServerMessage({
        type: 'event',
        session_id: sessionId,
        event: {
          type: 'message_start',
          data: [createUserMessage({ content: 'first insert', timestamp: sameTimestamp })],
        },
      } as unknown as EventMessage);

      store.applyServerMessage({
        type: 'event',
        session_id: sessionId,
        event: {
          type: 'message_start',
          data: [createAssistantMessage({ timestamp: sameTimestamp })],
        },
      } as unknown as EventMessage);

      const messages = useLemonStore.getState().messagesBySession[sessionId];

      expect(messages).toHaveLength(2);
      // First inserted should come first
      expect(messages[0]._insertionIndex).toBeLessThan(messages[1]._insertionIndex);
    });
  });

  describe('upsertMessage preserves original insertion index', () => {
    it('preserves insertion index when updating existing message', () => {
      const sessionId = 'test-session';
      const sameTimestamp = 1700000000000;
      const store = useLemonStore.getState();

      // First, add a message
      store.applyServerMessage({
        type: 'event',
        session_id: sessionId,
        event_seq: 1,
        event: {
          type: 'message_start',
          data: [createUserMessage({ content: 'original', timestamp: sameTimestamp })],
        },
      } as EventMessage);

      const messagesAfterFirst = useLemonStore.getState().messagesBySession[sessionId];
      const originalInsertionIndex = messagesAfterFirst[0]._insertionIndex;

      // Update the same message (same event_seq)
      store.applyServerMessage({
        type: 'event',
        session_id: sessionId,
        event_seq: 1,
        event: {
          type: 'message_update',
          data: [createUserMessage({ content: 'updated', timestamp: sameTimestamp })],
        },
      } as EventMessage);

      const messagesAfterUpdate = useLemonStore.getState().messagesBySession[sessionId];

      expect(messagesAfterUpdate).toHaveLength(1);
      expect(messagesAfterUpdate[0]._insertionIndex).toBe(originalInsertionIndex);
    });

    it('preserves earliest event_seq when updating with same event_seq', () => {
      const sessionId = 'test-session';
      const sameTimestamp = 1700000000000;
      const store = useLemonStore.getState();

      // First message_start with event_seq 5
      store.applyServerMessage({
        type: 'event',
        session_id: sessionId,
        event_seq: 5,
        event: {
          type: 'message_start',
          data: [createUserMessage({ content: 'start', timestamp: sameTimestamp })],
        },
      } as EventMessage);

      // message_update with same event_seq 5 (this is the typical case)
      store.applyServerMessage({
        type: 'event',
        session_id: sessionId,
        event_seq: 5,
        event: {
          type: 'message_update',
          data: [createUserMessage({ content: 'updated', timestamp: sameTimestamp })],
        },
      } as EventMessage);

      const messages = useLemonStore.getState().messagesBySession[sessionId];

      expect(messages).toHaveLength(1);
      // Should keep the original event_seq
      expect(messages[0]._event_seq).toBe(5);
    });

    it('treats messages with different event_seq as different messages', () => {
      const sessionId = 'test-session';
      const sameTimestamp = 1700000000000;
      const store = useLemonStore.getState();

      // First message with event_seq 5
      store.applyServerMessage({
        type: 'event',
        session_id: sessionId,
        event_seq: 5,
        event: {
          type: 'message_start',
          data: [createUserMessage({ content: 'first', timestamp: sameTimestamp })],
        },
      } as EventMessage);

      // Second message with different event_seq 10 (different message even with same timestamp)
      store.applyServerMessage({
        type: 'event',
        session_id: sessionId,
        event_seq: 10,
        event: {
          type: 'message_start',
          data: [createUserMessage({ content: 'second', timestamp: sameTimestamp })],
        },
      } as EventMessage);

      const messages = useLemonStore.getState().messagesBySession[sessionId];

      // Different event_seq means they're different messages (not merged)
      expect(messages).toHaveLength(2);
      expect(messages[0]._event_seq).toBe(5);
      expect(messages[1]._event_seq).toBe(10);
    });
  });

  describe('insertion counter management', () => {
    it('increments insertion counter per session', () => {
      const sessionId = 'test-session';
      const store = useLemonStore.getState();

      // Add multiple messages
      for (let i = 0; i < 3; i++) {
        store.applyServerMessage({
          type: 'event',
          session_id: sessionId,
          event_seq: i + 1,
          event: {
            type: 'message_start',
            data: [createUserMessage({ content: `msg ${i}`, timestamp: 1700000000000 + i })],
          },
        } as EventMessage);
      }

      const messages = useLemonStore.getState().messagesBySession[sessionId];

      expect(messages[0]._insertionIndex).toBe(0);
      expect(messages[1]._insertionIndex).toBe(1);
      expect(messages[2]._insertionIndex).toBe(2);
    });

    it('maintains separate counters for different sessions', () => {
      const store = useLemonStore.getState();

      store.applyServerMessage({
        type: 'event',
        session_id: 'session-1',
        event_seq: 1,
        event: {
          type: 'message_start',
          data: [createUserMessage({ content: 'session 1 msg 1' })],
        },
      } as EventMessage);

      store.applyServerMessage({
        type: 'event',
        session_id: 'session-2',
        event_seq: 1,
        event: {
          type: 'message_start',
          data: [createUserMessage({ content: 'session 2 msg 1' })],
        },
      } as EventMessage);

      store.applyServerMessage({
        type: 'event',
        session_id: 'session-1',
        event_seq: 2,
        event: {
          type: 'message_start',
          data: [createUserMessage({ content: 'session 1 msg 2' })],
        },
      } as EventMessage);

      const session1Messages = useLemonStore.getState().messagesBySession['session-1'];
      const session2Messages = useLemonStore.getState().messagesBySession['session-2'];

      expect(session1Messages[0]._insertionIndex).toBe(0);
      expect(session1Messages[1]._insertionIndex).toBe(1);
      expect(session2Messages[0]._insertionIndex).toBe(0);
    });

    it('cleans up insertion counter when session is closed', () => {
      const sessionId = 'test-session';
      const store = useLemonStore.getState();

      // Add a message to create the counter
      store.applyServerMessage({
        type: 'event',
        session_id: sessionId,
        event_seq: 1,
        event: {
          type: 'message_start',
          data: [createUserMessage({ content: 'test' })],
        },
      } as EventMessage);

      // Register the session as running first
      store.applyServerMessage({
        type: 'session_started',
        session_id: sessionId,
        cwd: '/test',
        model: { provider: 'test', id: 'test' },
      });

      expect(useLemonStore.getState()._insertionCounters[sessionId]).toBeDefined();

      // Close the session
      store.applyServerMessage({
        type: 'session_closed',
        session_id: sessionId,
        reason: 'normal',
      });

      expect(useLemonStore.getState()._insertionCounters[sessionId]).toBeUndefined();
    });
  });

  describe('agent_end event handling', () => {
    it('handles agent_end with multiple messages', () => {
      const sessionId = 'test-session';
      const store = useLemonStore.getState();

      store.applyServerMessage({
        type: 'event',
        session_id: sessionId,
        event_seq: 1,
        event: {
          type: 'agent_end',
          data: [[
            createUserMessage({ content: 'user input', timestamp: 1700000000000 }),
            createAssistantMessage({ timestamp: 1700000000001 }),
            createToolResultMessage({ tool_call_id: 'call-1', timestamp: 1700000000002 }),
          ]],
        },
      } as EventMessage);

      const messages = useLemonStore.getState().messagesBySession[sessionId];

      expect(messages).toHaveLength(3);
      // All messages should have the same event_seq
      expect(messages[0]._event_seq).toBe(1);
      expect(messages[1]._event_seq).toBe(1);
      expect(messages[2]._event_seq).toBe(1);
      // But different insertion indices
      expect(messages[0]._insertionIndex).toBe(0);
      expect(messages[1]._insertionIndex).toBe(1);
      expect(messages[2]._insertionIndex).toBe(2);
    });
  });
});
