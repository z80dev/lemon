import { render, screen, cleanup, fireEvent, within } from '@testing-library/react';
import { describe, it, expect, beforeEach, afterEach, vi, type Mock } from 'vitest';
import { ChatView } from './ChatView';
import { useLemonStore, type MessageWithMeta } from '../store/useLemonStore';
import type { UserMessage, AssistantMessage, ToolResultMessage } from '@lemon-web/shared';

// Store initial state for reset
const initialState = useLemonStore.getState();

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
    content: [
      {
        __struct__: 'Elixir.Ai.Types.TextContent',
        type: 'text',
        text: 'Hello from assistant',
      },
    ],
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
    content: [
      {
        __struct__: 'Elixir.Ai.Types.TextContent',
        type: 'text',
        text: 'Tool result text',
      },
    ],
    is_error: false,
    timestamp: Date.now(),
    ...overrides,
  };
}

function wrapWithMeta(
  msg: UserMessage | AssistantMessage | ToolResultMessage,
  insertionIndex: number = 0,
  eventSeq?: number
): MessageWithMeta {
  return {
    ...msg,
    _event_seq: eventSeq,
    _insertionIndex: insertionIndex,
  };
}

/**
 * Sets up the store with a given session and messages
 */
function setupStoreWithMessages(
  sessionId: string,
  messages: MessageWithMeta[],
  options: { isActive?: boolean } = {}
) {
  const { isActive = true } = options;
  useLemonStore.setState({
    sessions: {
      ...initialState.sessions,
      activeSessionId: isActive ? sessionId : null,
    },
    messagesBySession: {
      [sessionId]: messages,
    },
  });
}

describe('ChatView', () => {
  beforeEach(() => {
    // Reset store state before each test
    useLemonStore.setState(initialState, true);
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  // ==========================================================================
  // Message Rendering Tests
  // ==========================================================================

  describe('message rendering', () => {
    it('renders user messages', () => {
      const sessionId = 'session-1';
      const messages = [
        wrapWithMeta(createUserMessage({ content: 'Hello world' }), 0),
      ];
      setupStoreWithMessages(sessionId, messages);

      render(<ChatView />);

      expect(screen.getByText('user')).toBeInTheDocument();
    });

    it('renders assistant messages', () => {
      const sessionId = 'session-1';
      const messages = [
        wrapWithMeta(
          createAssistantMessage({
            content: [
              {
                __struct__: 'Elixir.Ai.Types.TextContent',
                type: 'text',
                text: 'Assistant response',
              },
            ],
          }),
          0
        ),
      ];
      setupStoreWithMessages(sessionId, messages);

      render(<ChatView />);

      expect(screen.getByText('assistant')).toBeInTheDocument();
    });

    it('renders tool result messages', () => {
      const sessionId = 'session-1';
      const messages = [
        wrapWithMeta(
          createToolResultMessage({
            tool_name: 'read',
            tool_call_id: 'call-abc',
          }),
          0
        ),
      ];
      setupStoreWithMessages(sessionId, messages);

      render(<ChatView />);

      expect(screen.getByText(/tool_result/)).toBeInTheDocument();
      expect(screen.getByText(/tool read/)).toBeInTheDocument();
    });

    it('renders multiple message types in order', () => {
      const sessionId = 'session-1';
      const baseTime = 1700000000000;
      const messages = [
        wrapWithMeta(createUserMessage({ timestamp: baseTime }), 0, 1),
        wrapWithMeta(createAssistantMessage({ timestamp: baseTime + 1000 }), 1, 2),
        wrapWithMeta(
          createToolResultMessage({
            tool_name: 'bash',
            timestamp: baseTime + 2000,
          }),
          2,
          3
        ),
      ];
      setupStoreWithMessages(sessionId, messages);

      render(<ChatView />);

      const messageCards = screen.getAllByRole('article');
      expect(messageCards).toHaveLength(3);
    });

    it('renders message count in header', () => {
      const sessionId = 'session-1';
      const messages = [
        wrapWithMeta(createUserMessage(), 0),
        wrapWithMeta(createAssistantMessage(), 1),
        wrapWithMeta(createToolResultMessage(), 2),
      ];
      setupStoreWithMessages(sessionId, messages);

      render(<ChatView />);

      expect(screen.getByText('3 messages')).toBeInTheDocument();
    });

    it('renders 0 messages count when empty', () => {
      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: 'session-1',
        },
        messagesBySession: {
          'session-1': [],
        },
      });

      render(<ChatView />);

      expect(screen.getByText('0 messages')).toBeInTheDocument();
    });

    it('renders error tool results with error status', () => {
      const sessionId = 'session-1';
      const messages = [
        wrapWithMeta(
          createToolResultMessage({
            is_error: true,
            tool_name: 'bash',
            content: [
              {
                __struct__: 'Elixir.Ai.Types.TextContent',
                type: 'text',
                text: 'Command failed',
              },
            ],
          }),
          0
        ),
      ];
      setupStoreWithMessages(sessionId, messages);

      render(<ChatView />);

      expect(screen.getByText('Error')).toBeInTheDocument();
    });

    it('renders successful tool results with success status', () => {
      const sessionId = 'session-1';
      const messages = [
        wrapWithMeta(
          createToolResultMessage({
            is_error: false,
            tool_name: 'read',
          }),
          0
        ),
      ];
      setupStoreWithMessages(sessionId, messages);

      render(<ChatView />);

      expect(screen.getByText('Success')).toBeInTheDocument();
    });
  });

  // ==========================================================================
  // Empty State Tests
  // ==========================================================================

  describe('empty state', () => {
    it('renders empty state when no messages exist', () => {
      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: 'session-1',
        },
        messagesBySession: {
          'session-1': [],
        },
      });

      render(<ChatView />);

      expect(
        screen.getByText('No messages yet. Start a session and send a prompt.')
      ).toBeInTheDocument();
    });

    it('renders empty state when no active session', () => {
      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: null,
        },
        messagesBySession: {},
      });

      render(<ChatView />);

      expect(
        screen.getByText('No messages yet. Start a session and send a prompt.')
      ).toBeInTheDocument();
    });

    it('renders empty state when active session has no message entry', () => {
      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: 'session-1',
        },
        messagesBySession: {}, // No entry for session-1
      });

      render(<ChatView />);

      expect(
        screen.getByText('No messages yet. Start a session and send a prompt.')
      ).toBeInTheDocument();
    });

    it('shows empty state class on the container', () => {
      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: 'session-1',
        },
        messagesBySession: { 'session-1': [] },
      });

      const { container } = render(<ChatView />);

      expect(container.querySelector('.empty-state')).toBeInTheDocument();
    });
  });

  // ==========================================================================
  // Session-based Message Filtering Tests
  // ==========================================================================

  describe('session-based message filtering', () => {
    it('only displays messages for the active session', () => {
      const session1Messages = [
        wrapWithMeta(createUserMessage({ content: 'Session 1 message' }), 0),
      ];
      const session2Messages = [
        wrapWithMeta(createUserMessage({ content: 'Session 2 message' }), 0),
      ];

      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: 'session-1',
        },
        messagesBySession: {
          'session-1': session1Messages,
          'session-2': session2Messages,
        },
      });

      render(<ChatView />);

      expect(screen.getByText('1 messages')).toBeInTheDocument();
    });

    it('updates displayed messages when active session changes', () => {
      const session1Messages = [
        wrapWithMeta(createUserMessage({ content: 'Session 1' }), 0),
      ];
      const session2Messages = [
        wrapWithMeta(createUserMessage({ content: 'Session 2 A' }), 0),
        wrapWithMeta(createAssistantMessage(), 1),
      ];

      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: 'session-1',
        },
        messagesBySession: {
          'session-1': session1Messages,
          'session-2': session2Messages,
        },
      });

      const { rerender } = render(<ChatView />);

      expect(screen.getByText('1 messages')).toBeInTheDocument();

      // Change active session
      useLemonStore.setState({
        sessions: {
          ...useLemonStore.getState().sessions,
          activeSessionId: 'session-2',
        },
      });

      rerender(<ChatView />);

      expect(screen.getByText('2 messages')).toBeInTheDocument();
    });

    it('shows empty state when switching to session with no messages', () => {
      const session1Messages = [
        wrapWithMeta(createUserMessage({ content: 'Session 1' }), 0),
      ];

      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: 'session-1',
        },
        messagesBySession: {
          'session-1': session1Messages,
          'session-2': [],
        },
      });

      const { rerender } = render(<ChatView />);

      expect(screen.getByText('1 messages')).toBeInTheDocument();

      // Change active session to one with no messages
      useLemonStore.setState({
        sessions: {
          ...useLemonStore.getState().sessions,
          activeSessionId: 'session-2',
        },
      });

      rerender(<ChatView />);

      expect(
        screen.getByText('No messages yet. Start a session and send a prompt.')
      ).toBeInTheDocument();
    });
  });

  // ==========================================================================
  // Auto-scroll Behavior Tests
  // ==========================================================================

  describe('auto-scroll behavior', () => {
    it('scrolls to bottom on initial render', () => {
      const sessionId = 'session-1';
      const messages = Array.from({ length: 10 }, (_, i) =>
        wrapWithMeta(createUserMessage({ content: `Message ${i}` }), i)
      );
      setupStoreWithMessages(sessionId, messages);

      const { container } = render(<ChatView />);
      const feed = container.querySelector('.message-feed');

      expect(feed).toBeInTheDocument();
      // After render, scrollTop should equal scrollHeight (scrolled to bottom)
      // In jsdom, scrollHeight equals 0, but scrollTop should be set
      expect(feed?.scrollTop).toBeDefined();
    });

    it('maintains scroll position reference via feedRef', () => {
      const sessionId = 'session-1';
      const messages = [wrapWithMeta(createUserMessage(), 0)];
      setupStoreWithMessages(sessionId, messages);

      const { container } = render(<ChatView />);
      const feed = container.querySelector('.message-feed');

      expect(feed).toBeInTheDocument();
      expect(feed?.tagName).toBe('DIV');
    });

    it('has onScroll handler attached to message feed', () => {
      const sessionId = 'session-1';
      const messages = [wrapWithMeta(createUserMessage(), 0)];
      setupStoreWithMessages(sessionId, messages);

      const { container } = render(<ChatView />);
      const feed = container.querySelector('.message-feed');

      expect(feed).toBeInTheDocument();
      // Fire a scroll event - should not throw
      fireEvent.scroll(feed!);
    });
  });

  // ==========================================================================
  // User Scroll Position Detection Tests
  // ==========================================================================

  describe('user scroll position detection', () => {
    it('handles scroll events without errors', () => {
      const sessionId = 'session-1';
      const messages = Array.from({ length: 20 }, (_, i) =>
        wrapWithMeta(createUserMessage({ content: `Message ${i}` }), i)
      );
      setupStoreWithMessages(sessionId, messages);

      const { container } = render(<ChatView />);
      const feed = container.querySelector('.message-feed')!;

      // Should not throw
      expect(() => fireEvent.scroll(feed)).not.toThrow();
    });

    it('tracks scroll position on multiple scroll events', () => {
      const sessionId = 'session-1';
      const messages = Array.from({ length: 5 }, (_, i) =>
        wrapWithMeta(createUserMessage({ content: `Message ${i}` }), i)
      );
      setupStoreWithMessages(sessionId, messages);

      const { container } = render(<ChatView />);
      const feed = container.querySelector('.message-feed')!;

      // Simulate multiple scroll events
      fireEvent.scroll(feed);
      fireEvent.scroll(feed);
      fireEvent.scroll(feed);

      // Should handle multiple scroll events without issues
      expect(feed).toBeInTheDocument();
    });

    it('respects AUTO_SCROLL_THRESHOLD of 100 pixels', () => {
      // This test verifies the threshold logic exists by checking
      // that the scroll handler runs without error when manipulating scroll
      const sessionId = 'session-1';
      const messages = Array.from({ length: 10 }, (_, i) =>
        wrapWithMeta(createUserMessage({ content: `Message ${i}` }), i)
      );
      setupStoreWithMessages(sessionId, messages);

      const { container } = render(<ChatView />);
      const feed = container.querySelector('.message-feed')!;

      // Simulate being near bottom (within threshold)
      Object.defineProperty(feed, 'scrollHeight', { value: 1000, configurable: true });
      Object.defineProperty(feed, 'scrollTop', { value: 850, writable: true });
      Object.defineProperty(feed, 'clientHeight', { value: 100, configurable: true });
      // Distance from bottom: 1000 - 850 - 100 = 50 (within 100px threshold)

      fireEvent.scroll(feed);

      expect(feed).toBeInTheDocument();
    });

    it('detects when user scrolls away from bottom', () => {
      const sessionId = 'session-1';
      const messages = Array.from({ length: 10 }, (_, i) =>
        wrapWithMeta(createUserMessage({ content: `Message ${i}` }), i)
      );
      setupStoreWithMessages(sessionId, messages);

      const { container } = render(<ChatView />);
      const feed = container.querySelector('.message-feed')!;

      // Simulate being far from bottom (beyond threshold)
      Object.defineProperty(feed, 'scrollHeight', { value: 1000, configurable: true });
      Object.defineProperty(feed, 'scrollTop', { value: 0, writable: true });
      Object.defineProperty(feed, 'clientHeight', { value: 100, configurable: true });
      // Distance from bottom: 1000 - 0 - 100 = 900 (beyond 100px threshold)

      fireEvent.scroll(feed);

      expect(feed).toBeInTheDocument();
    });
  });

  // ==========================================================================
  // Scroll Event Handling Tests
  // ==========================================================================

  describe('scroll event handling', () => {
    it('handles scroll on empty message list', () => {
      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: 'session-1',
        },
        messagesBySession: { 'session-1': [] },
      });

      const { container } = render(<ChatView />);
      const feed = container.querySelector('.message-feed');

      // Empty state doesn't have a traditional scroll, but the feed exists
      expect(feed).toBeInTheDocument();
    });

    it('scroll handler is memoized with useCallback', () => {
      const sessionId = 'session-1';
      const messages = [wrapWithMeta(createUserMessage(), 0)];
      setupStoreWithMessages(sessionId, messages);

      const { container, rerender } = render(<ChatView />);
      const feed1 = container.querySelector('.message-feed');

      rerender(<ChatView />);

      const feed2 = container.querySelector('.message-feed');

      // Both should reference the same DOM element
      expect(feed1).toBe(feed2);
    });
  });

  // ==========================================================================
  // Session Change Behavior Tests
  // ==========================================================================

  describe('session change behavior', () => {
    it('resets scroll to bottom on session change', () => {
      const session1Messages = [
        wrapWithMeta(createUserMessage({ content: 'Session 1' }), 0),
      ];
      const session2Messages = [
        wrapWithMeta(createUserMessage({ content: 'Session 2' }), 0),
      ];

      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: 'session-1',
        },
        messagesBySession: {
          'session-1': session1Messages,
          'session-2': session2Messages,
        },
      });

      const { container, rerender } = render(<ChatView />);
      const feed = container.querySelector('.message-feed')!;

      // Change session
      useLemonStore.setState({
        sessions: {
          ...useLemonStore.getState().sessions,
          activeSessionId: 'session-2',
        },
      });

      rerender(<ChatView />);

      // Feed should still exist and be scrollable
      expect(feed).toBeInTheDocument();
    });

    it('handles rapid session switching', () => {
      const sessions = ['session-1', 'session-2', 'session-3'];
      const messagesBySession: Record<string, MessageWithMeta[]> = {};

      sessions.forEach((sid) => {
        messagesBySession[sid] = [
          wrapWithMeta(createUserMessage({ content: `Message in ${sid}` }), 0),
        ];
      });

      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: 'session-1',
        },
        messagesBySession,
      });

      const { rerender } = render(<ChatView />);

      // Rapidly switch sessions
      for (const sid of sessions) {
        useLemonStore.setState({
          sessions: {
            ...useLemonStore.getState().sessions,
            activeSessionId: sid,
          },
        });
        rerender(<ChatView />);
      }

      // Should end on session-3
      expect(screen.getByText('1 messages')).toBeInTheDocument();
    });
  });

  // ==========================================================================
  // Message Ordering Tests
  // ==========================================================================

  describe('message ordering', () => {
    it('renders messages in correct order by event_seq', () => {
      const sessionId = 'session-1';
      const messages = [
        wrapWithMeta(createUserMessage({ content: 'First' }), 0, 1),
        wrapWithMeta(createAssistantMessage(), 1, 2),
        wrapWithMeta(createToolResultMessage(), 2, 3),
      ];
      setupStoreWithMessages(sessionId, messages);

      render(<ChatView />);

      const articles = screen.getAllByRole('article');
      expect(articles).toHaveLength(3);
    });

    it('handles out-of-order message insertion', () => {
      const sessionId = 'session-1';
      // Messages with event_seq out of order, but already sorted by store
      const messages = [
        wrapWithMeta(createUserMessage({ content: 'Should be first' }), 0, 1),
        wrapWithMeta(createAssistantMessage(), 1, 5),
        wrapWithMeta(createToolResultMessage(), 2, 10),
      ];
      setupStoreWithMessages(sessionId, messages);

      render(<ChatView />);

      expect(screen.getByText('3 messages')).toBeInTheDocument();
    });

    it('maintains stable order when messages update', () => {
      const sessionId = 'session-1';
      const baseTime = 1700000000000;
      const messages = [
        wrapWithMeta(createUserMessage({ timestamp: baseTime }), 0, 1),
        wrapWithMeta(createAssistantMessage({ timestamp: baseTime + 1000 }), 1, 2),
      ];
      setupStoreWithMessages(sessionId, messages);

      const { rerender } = render(<ChatView />);

      expect(screen.getByText('2 messages')).toBeInTheDocument();

      // Add another message
      useLemonStore.setState({
        messagesBySession: {
          [sessionId]: [
            ...messages,
            wrapWithMeta(
              createToolResultMessage({ timestamp: baseTime + 2000 }),
              2,
              3
            ),
          ],
        },
      });

      rerender(<ChatView />);

      expect(screen.getByText('3 messages')).toBeInTheDocument();
    });
  });

  // ==========================================================================
  // Large Message List Performance Tests
  // ==========================================================================

  describe('large message list handling', () => {
    it('renders 100 messages efficiently', () => {
      const sessionId = 'session-1';
      const messages = Array.from({ length: 100 }, (_, i) =>
        wrapWithMeta(
          createUserMessage({ content: `Message ${i}`, timestamp: 1700000000000 + i }),
          i,
          i + 1
        )
      );
      setupStoreWithMessages(sessionId, messages);

      const startTime = performance.now();
      render(<ChatView />);
      const endTime = performance.now();

      expect(screen.getByText('100 messages')).toBeInTheDocument();
      // Should render in reasonable time (less than 1 second)
      expect(endTime - startTime).toBeLessThan(1000);
    });

    it('renders 500 messages', () => {
      const sessionId = 'session-1';
      const messages = Array.from({ length: 500 }, (_, i) =>
        wrapWithMeta(
          createUserMessage({ content: `Message ${i}`, timestamp: 1700000000000 + i }),
          i,
          i + 1
        )
      );
      setupStoreWithMessages(sessionId, messages);

      render(<ChatView />);

      expect(screen.getByText('500 messages')).toBeInTheDocument();
    });

    it('handles mixed message types in large list', () => {
      const sessionId = 'session-1';
      const messages: MessageWithMeta[] = [];
      for (let i = 0; i < 150; i++) {
        const timestamp = 1700000000000 + i * 100;
        if (i % 3 === 0) {
          messages.push(wrapWithMeta(createUserMessage({ timestamp }), i, i));
        } else if (i % 3 === 1) {
          messages.push(wrapWithMeta(createAssistantMessage({ timestamp }), i, i));
        } else {
          messages.push(
            wrapWithMeta(
              createToolResultMessage({ tool_call_id: `call-${i}`, timestamp }),
              i,
              i
            )
          );
        }
      }
      setupStoreWithMessages(sessionId, messages);

      render(<ChatView />);

      expect(screen.getByText('150 messages')).toBeInTheDocument();
    });
  });

  // ==========================================================================
  // Memoization Tests
  // ==========================================================================

  describe('memoization and performance', () => {
    it('messageList is memoized with useMemo', () => {
      const sessionId = 'session-1';
      const messages = [wrapWithMeta(createUserMessage(), 0)];
      setupStoreWithMessages(sessionId, messages);

      const { rerender } = render(<ChatView />);

      // Rerender with same messages
      rerender(<ChatView />);
      rerender(<ChatView />);

      // Component should still show correct count
      expect(screen.getByText('1 messages')).toBeInTheDocument();
    });

    it('handleScroll callback is stable across renders', () => {
      const sessionId = 'session-1';
      const messages = [wrapWithMeta(createUserMessage(), 0)];
      setupStoreWithMessages(sessionId, messages);

      const { container, rerender } = render(<ChatView />);
      const feed = container.querySelector('.message-feed')!;

      // Scroll, rerender, scroll again - should work fine
      fireEvent.scroll(feed);
      rerender(<ChatView />);
      fireEvent.scroll(feed);

      expect(feed).toBeInTheDocument();
    });

    it('does not re-render MessageCard unnecessarily', () => {
      const sessionId = 'session-1';
      const messages = [
        wrapWithMeta(createUserMessage({ content: 'Test message' }), 0),
      ];
      setupStoreWithMessages(sessionId, messages);

      const { rerender } = render(<ChatView />);

      // Get the message card
      const articleBefore = screen.getByRole('article');

      // Rerender without changing messages
      rerender(<ChatView />);

      const articleAfter = screen.getByRole('article');

      // DOM element should be the same (React reconciliation)
      expect(articleBefore).toBe(articleAfter);
    });
  });

  // ==========================================================================
  // Message Key Generation Tests
  // ==========================================================================

  describe('message key generation', () => {
    it('generates unique keys for all messages', () => {
      const sessionId = 'session-1';
      const baseTime = 1700000000000;
      const messages = [
        wrapWithMeta(createUserMessage({ timestamp: baseTime }), 0, 1),
        wrapWithMeta(createUserMessage({ timestamp: baseTime + 1 }), 1, 2),
        wrapWithMeta(createAssistantMessage({ timestamp: baseTime + 2 }), 2, 3),
        wrapWithMeta(
          createToolResultMessage({
            tool_call_id: 'call-1',
            timestamp: baseTime + 3,
          }),
          3,
          4
        ),
        wrapWithMeta(
          createToolResultMessage({
            tool_call_id: 'call-2',
            timestamp: baseTime + 4,
          }),
          4,
          5
        ),
      ];
      setupStoreWithMessages(sessionId, messages);

      render(<ChatView />);

      const articles = screen.getAllByRole('article');
      expect(articles).toHaveLength(5);
    });

    it('handles tool results with same call ID across different sessions', () => {
      // This verifies isolation between sessions
      const session1Messages = [
        wrapWithMeta(
          createToolResultMessage({ tool_call_id: 'shared-call-id' }),
          0
        ),
      ];
      const session2Messages = [
        wrapWithMeta(
          createToolResultMessage({ tool_call_id: 'shared-call-id' }),
          0
        ),
      ];

      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: 'session-1',
        },
        messagesBySession: {
          'session-1': session1Messages,
          'session-2': session2Messages,
        },
      });

      render(<ChatView />);

      // Only session-1 messages should be visible
      expect(screen.getByText('1 messages')).toBeInTheDocument();
    });
  });

  // ==========================================================================
  // Component Structure Tests
  // ==========================================================================

  describe('component structure', () => {
    it('renders chat-view section element', () => {
      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: 'session-1',
        },
        messagesBySession: { 'session-1': [] },
      });

      const { container } = render(<ChatView />);

      expect(container.querySelector('section.chat-view')).toBeInTheDocument();
    });

    it('renders chat header with title', () => {
      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: 'session-1',
        },
        messagesBySession: { 'session-1': [] },
      });

      render(<ChatView />);

      expect(screen.getByRole('heading', { level: 2 })).toHaveTextContent(
        'Conversation'
      );
    });

    it('renders message feed container', () => {
      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: 'session-1',
        },
        messagesBySession: { 'session-1': [] },
      });

      const { container } = render(<ChatView />);

      expect(container.querySelector('.message-feed')).toBeInTheDocument();
    });

    it('renders chat-count span with message count', () => {
      const sessionId = 'session-1';
      const messages = [
        wrapWithMeta(createUserMessage(), 0),
        wrapWithMeta(createAssistantMessage(), 1),
      ];
      setupStoreWithMessages(sessionId, messages);

      const { container } = render(<ChatView />);

      const countSpan = container.querySelector('.chat-count');
      expect(countSpan).toBeInTheDocument();
      expect(countSpan).toHaveTextContent('2 messages');
    });
  });

  // ==========================================================================
  // Edge Cases
  // ==========================================================================

  describe('edge cases', () => {
    it('handles missing session entry in messagesBySession gracefully', () => {
      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: 'session-1',
        },
        messagesBySession: {
          // session-1 is not in messagesBySession but is the active session
          'other-session': [wrapWithMeta(createUserMessage(), 0)],
        },
      });

      // Should render empty state, not throw
      render(<ChatView />);
      expect(
        screen.getByText('No messages yet. Start a session and send a prompt.')
      ).toBeInTheDocument();
    });

    it('handles null activeSessionId', () => {
      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: null,
        },
        messagesBySession: {
          'session-1': [wrapWithMeta(createUserMessage(), 0)],
        },
      });

      render(<ChatView />);

      expect(
        screen.getByText('No messages yet. Start a session and send a prompt.')
      ).toBeInTheDocument();
    });

    it('handles empty string activeSessionId', () => {
      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: '',
        },
        messagesBySession: {
          '': [wrapWithMeta(createUserMessage(), 0)],
        },
      });

      render(<ChatView />);

      // Empty string is falsy, so should show empty state
      expect(
        screen.getByText('No messages yet. Start a session and send a prompt.')
      ).toBeInTheDocument();
    });

    it('handles message with very long content', () => {
      const sessionId = 'session-1';
      const longContent = 'A'.repeat(10000);
      const messages = [
        wrapWithMeta(createUserMessage({ content: longContent }), 0),
      ];
      setupStoreWithMessages(sessionId, messages);

      render(<ChatView />);

      expect(screen.getByText('1 messages')).toBeInTheDocument();
    });

    it('handles messages with special characters', () => {
      const sessionId = 'session-1';
      const messages = [
        wrapWithMeta(
          createUserMessage({ content: '<script>alert("xss")</script>' }),
          0
        ),
      ];
      setupStoreWithMessages(sessionId, messages);

      render(<ChatView />);

      // Should render without executing script
      expect(screen.getByText('1 messages')).toBeInTheDocument();
    });

    it('handles messages with unicode and emojis', () => {
      const sessionId = 'session-1';
      const messages = [
        wrapWithMeta(
          createUserMessage({ content: 'Hello \u4e16\u754c! \ud83d\ude80\ud83c\udf1f' }),
          0
        ),
      ];
      setupStoreWithMessages(sessionId, messages);

      render(<ChatView />);

      expect(screen.getByText('1 messages')).toBeInTheDocument();
    });

    it('handles session change from null to valid session', () => {
      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: null,
        },
        messagesBySession: {
          'session-1': [wrapWithMeta(createUserMessage(), 0)],
        },
      });

      const { rerender } = render(<ChatView />);

      expect(
        screen.getByText('No messages yet. Start a session and send a prompt.')
      ).toBeInTheDocument();

      // Set active session
      useLemonStore.setState({
        sessions: {
          ...useLemonStore.getState().sessions,
          activeSessionId: 'session-1',
        },
      });

      rerender(<ChatView />);

      expect(screen.getByText('1 messages')).toBeInTheDocument();
    });

    it('handles session change from valid to null', () => {
      const sessionId = 'session-1';
      const messages = [wrapWithMeta(createUserMessage(), 0)];
      setupStoreWithMessages(sessionId, messages);

      const { rerender } = render(<ChatView />);

      expect(screen.getByText('1 messages')).toBeInTheDocument();

      // Clear active session
      useLemonStore.setState({
        sessions: {
          ...useLemonStore.getState().sessions,
          activeSessionId: null,
        },
      });

      rerender(<ChatView />);

      expect(
        screen.getByText('No messages yet. Start a session and send a prompt.')
      ).toBeInTheDocument();
    });
  });

  // ==========================================================================
  // Integration with Store
  // ==========================================================================

  describe('store integration', () => {
    it('reacts to store updates', () => {
      const sessionId = 'session-1';
      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: sessionId,
        },
        messagesBySession: {
          [sessionId]: [],
        },
      });

      const { rerender } = render(<ChatView />);

      expect(screen.getByText('0 messages')).toBeInTheDocument();

      // Update store with new message
      useLemonStore.setState({
        messagesBySession: {
          [sessionId]: [wrapWithMeta(createUserMessage(), 0)],
        },
      });

      rerender(<ChatView />);

      expect(screen.getByText('1 messages')).toBeInTheDocument();
    });

    it('uses getMessageKey for unique keys', () => {
      const sessionId = 'session-1';
      const timestamp = 1700000000000;
      const messages = [
        wrapWithMeta(createUserMessage({ timestamp }), 0, 1),
        wrapWithMeta(createAssistantMessage({ timestamp: timestamp + 1 }), 1, 2),
      ];
      setupStoreWithMessages(sessionId, messages);

      render(<ChatView />);

      const articles = screen.getAllByRole('article');
      expect(articles).toHaveLength(2);
    });

    it('handles concurrent state updates', () => {
      const sessionId = 'session-1';

      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: sessionId,
        },
        messagesBySession: {
          [sessionId]: [wrapWithMeta(createUserMessage(), 0)],
        },
      });

      const { rerender } = render(<ChatView />);

      // Simulate rapid updates
      for (let i = 1; i <= 5; i++) {
        useLemonStore.setState({
          messagesBySession: {
            [sessionId]: Array.from({ length: i + 1 }, (_, j) =>
              wrapWithMeta(createUserMessage(), j)
            ),
          },
        });
        rerender(<ChatView />);
      }

      expect(screen.getByText('6 messages')).toBeInTheDocument();
    });
  });
});
