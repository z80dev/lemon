import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { TopBar } from './TopBar';
import { useLemonStore } from '../store/useLemonStore';
import type { SessionStats } from '@lemon-web/shared';

/**
 * Test helper to set up store state for TopBar tests
 */
function setupStore(overrides: {
  title?: string | null;
  connectionState?: 'connecting' | 'connected' | 'disconnected' | 'error';
  lastError?: string | null;
  lastServerTime?: number;
  bridgeStatus?: string | null;
  activeSessionId?: string | null;
  stats?: SessionStats;
  queueCount?: number;
  pendingConfirmations?: Array<{
    payload: string;
    enqueuedAt: number;
    ttlMs: number;
    sessionIdAtEnqueue: string | null;
    commandType: string;
  }>;
  sendCommand?: (cmd: unknown) => void;
} = {}) {
  const mockSend = overrides.sendCommand ?? vi.fn();

  useLemonStore.setState({
    ui: {
      requestsQueue: [],
      status: {},
      widgets: {},
      workingMessage: null,
      title: overrides.title ?? null,
      editorText: '',
    },
    connection: {
      state: overrides.connectionState ?? 'connected',
      lastError: overrides.lastError ?? null,
      lastServerTime: overrides.lastServerTime,
      bridgeStatus: overrides.bridgeStatus ?? null,
    },
    sessions: {
      running: {},
      saved: [],
      activeSessionId: overrides.activeSessionId ?? null,
      primarySessionId: null,
    },
    statsBySession: overrides.stats
      ? { [overrides.stats.session_id]: overrides.stats }
      : {},
    queue: {
      count: overrides.queueCount ?? 0,
      pendingConfirmations: overrides.pendingConfirmations ?? [],
    },
    sendCommand: mockSend,
  });

  return { mockSend };
}

/**
 * Create a mock SessionStats object
 */
function createStats(overrides: Partial<SessionStats> = {}): SessionStats {
  return {
    session_id: 'test-session',
    message_count: 10,
    turn_count: 5,
    is_streaming: false,
    cwd: '/test/path',
    model: {
      provider: 'anthropic',
      id: 'claude-3-opus',
    },
    thinking_level: null,
    ...overrides,
  };
}

describe('TopBar', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2024-01-15T12:00:00Z'));
  });

  afterEach(() => {
    vi.useRealTimers();
    useLemonStore.setState({
      ui: {
        requestsQueue: [],
        status: {},
        widgets: {},
        workingMessage: null,
        title: null,
        editorText: '',
      },
      connection: {
        state: 'connecting',
        lastError: null,
        lastServerTime: undefined,
        bridgeStatus: null,
      },
      sessions: {
        running: {},
        saved: [],
        activeSessionId: null,
        primarySessionId: null,
      },
      statsBySession: {},
      queue: {
        count: 0,
        pendingConfirmations: [],
      },
      sendCommand: undefined,
    });
  });

  // =========================================================================
  // Connection State Display Tests
  // =========================================================================

  describe('connection state display', () => {
    it('displays "Connected" when connection state is connected', () => {
      setupStore({ connectionState: 'connected' });
      render(<TopBar />);

      expect(screen.getByText('Connected')).toBeInTheDocument();
    });

    it('displays "Connecting..." when connection state is connecting', () => {
      setupStore({ connectionState: 'connecting' });
      render(<TopBar />);

      expect(screen.getByText('Connecting…')).toBeInTheDocument();
    });

    it('displays "Disconnected" when connection state is disconnected', () => {
      setupStore({ connectionState: 'disconnected' });
      render(<TopBar />);

      expect(screen.getByText('Disconnected')).toBeInTheDocument();
    });

    it('displays "Error" when connection state is error', () => {
      setupStore({ connectionState: 'error' });
      render(<TopBar />);

      expect(screen.getByText('Error')).toBeInTheDocument();
    });

    it('applies correct CSS class for connected state', () => {
      setupStore({ connectionState: 'connected' });
      render(<TopBar />);

      const pill = screen.getByText('Connected').closest('.connection-pill');
      expect(pill).toHaveClass('connection-pill--connected');
    });

    it('applies correct CSS class for disconnected state', () => {
      setupStore({ connectionState: 'disconnected' });
      render(<TopBar />);

      const pill = screen.getByText('Disconnected').closest('.connection-pill');
      expect(pill).toHaveClass('connection-pill--disconnected');
    });

    it('applies correct CSS class for connecting state', () => {
      setupStore({ connectionState: 'connecting' });
      render(<TopBar />);

      const pill = screen.getByText('Connecting…').closest('.connection-pill');
      expect(pill).toHaveClass('connection-pill--connecting');
    });

    it('applies correct CSS class for error state', () => {
      setupStore({ connectionState: 'error' });
      render(<TopBar />);

      const pill = screen.getByText('Error').closest('.connection-pill');
      expect(pill).toHaveClass('connection-pill--error');
    });
  });

  // =========================================================================
  // Relative Time Formatting Tests
  // =========================================================================

  describe('relative time formatting', () => {
    it('displays "just now" for events less than 1 minute ago', () => {
      const now = Date.now();
      setupStore({
        connectionState: 'connected',
        lastServerTime: now - 30000, // 30 seconds ago
      });
      render(<TopBar />);

      expect(screen.getByText(/Last event: just now/)).toBeInTheDocument();
    });

    it('displays "1m ago" for events 1 minute ago', () => {
      const now = Date.now();
      setupStore({
        connectionState: 'connected',
        lastServerTime: now - 60000, // exactly 1 minute ago
      });
      render(<TopBar />);

      expect(screen.getByText(/Last event: 1m ago/)).toBeInTheDocument();
    });

    it('displays "5m ago" for events 5 minutes ago', () => {
      const now = Date.now();
      setupStore({
        connectionState: 'connected',
        lastServerTime: now - 300000, // 5 minutes ago
      });
      render(<TopBar />);

      expect(screen.getByText(/Last event: 5m ago/)).toBeInTheDocument();
    });

    it('displays "59m ago" for events 59 minutes ago', () => {
      const now = Date.now();
      setupStore({
        connectionState: 'connected',
        lastServerTime: now - 59 * 60000, // 59 minutes ago
      });
      render(<TopBar />);

      expect(screen.getByText(/Last event: 59m ago/)).toBeInTheDocument();
    });

    it('displays absolute time for events more than 1 hour ago', () => {
      const now = Date.now();
      setupStore({
        connectionState: 'connected',
        lastServerTime: now - 3600000, // exactly 1 hour ago
      });
      render(<TopBar />);

      // Should show localized time string (not "Xm ago")
      const serverTimeElement = screen.getByText(/Last event:/);
      expect(serverTimeElement).toBeInTheDocument();
      // Should NOT contain "m ago"
      expect(serverTimeElement.textContent).not.toMatch(/\d+m ago/);
    });

    it('does not display server time when lastServerTime is undefined', () => {
      setupStore({
        connectionState: 'connected',
        lastServerTime: undefined,
      });
      render(<TopBar />);

      expect(screen.queryByText(/Last event:/)).not.toBeInTheDocument();
    });

    it('does not display server time when disconnected', () => {
      const now = Date.now();
      setupStore({
        connectionState: 'disconnected',
        lastServerTime: now - 30000,
      });
      render(<TopBar />);

      expect(screen.queryByText(/Last event:/)).not.toBeInTheDocument();
    });

    it('does not display server time when connecting', () => {
      const now = Date.now();
      setupStore({
        connectionState: 'connecting',
        lastServerTime: now - 30000,
      });
      render(<TopBar />);

      expect(screen.queryByText(/Last event:/)).not.toBeInTheDocument();
    });
  });

  // =========================================================================
  // Queue Indicator Tests
  // =========================================================================

  describe('queue indicator display', () => {
    it('displays queue count when commands are queued', () => {
      setupStore({ queueCount: 3 });
      render(<TopBar />);

      expect(screen.getByText('Queued: 3')).toBeInTheDocument();
    });

    it('does not display queue indicator when count is 0', () => {
      setupStore({ queueCount: 0 });
      render(<TopBar />);

      expect(screen.queryByText(/Queued:/)).not.toBeInTheDocument();
    });

    it('displays queue indicator with correct CSS class', () => {
      setupStore({ queueCount: 5 });
      render(<TopBar />);

      const indicator = screen.getByText('Queued: 5');
      expect(indicator).toHaveClass('queue-indicator');
    });

    it('updates queue count when store changes', () => {
      setupStore({ queueCount: 2 });
      const { rerender } = render(<TopBar />);

      expect(screen.getByText('Queued: 2')).toBeInTheDocument();

      useLemonStore.setState((state) => ({
        queue: { ...state.queue, count: 7 },
      }));
      rerender(<TopBar />);

      expect(screen.getByText('Queued: 7')).toBeInTheDocument();
    });
  });

  // =========================================================================
  // Pending Confirmations Indicator Tests
  // =========================================================================

  describe('pending confirmations indicator', () => {
    it('displays pending count when confirmations are pending', () => {
      setupStore({
        pendingConfirmations: [
          {
            payload: '{"type":"abort"}',
            enqueuedAt: Date.now(),
            ttlMs: 30000,
            sessionIdAtEnqueue: 'session-1',
            commandType: 'abort',
          },
          {
            payload: '{"type":"reset"}',
            enqueuedAt: Date.now(),
            ttlMs: 30000,
            sessionIdAtEnqueue: 'session-1',
            commandType: 'reset',
          },
        ],
      });
      render(<TopBar />);

      expect(screen.getByText('Pending: 2')).toBeInTheDocument();
    });

    it('does not display pending indicator when no confirmations pending', () => {
      setupStore({ pendingConfirmations: [] });
      render(<TopBar />);

      expect(screen.queryByText(/Pending:/)).not.toBeInTheDocument();
    });

    it('displays pending indicator with warning CSS class', () => {
      setupStore({
        pendingConfirmations: [
          {
            payload: '{"type":"abort"}',
            enqueuedAt: Date.now(),
            ttlMs: 30000,
            sessionIdAtEnqueue: 'session-1',
            commandType: 'abort',
          },
        ],
      });
      render(<TopBar />);

      const indicator = screen.getByText('Pending: 1');
      expect(indicator).toHaveClass('queue-indicator');
      expect(indicator).toHaveClass('queue-indicator--warning');
    });
  });

  // =========================================================================
  // Bridge Status Display Tests
  // =========================================================================

  describe('bridge status display', () => {
    it('displays bridge status when set', () => {
      setupStore({ bridgeStatus: 'Bridge running on port 8080' });
      render(<TopBar />);

      expect(screen.getByText('Bridge running on port 8080')).toBeInTheDocument();
    });

    it('does not display bridge status when null', () => {
      setupStore({ bridgeStatus: null });
      render(<TopBar />);

      expect(screen.queryByText(/Bridge/)).not.toBeInTheDocument();
    });

    it('displays bridge status with correct CSS class', () => {
      setupStore({ bridgeStatus: 'Starting bridge...' });
      render(<TopBar />);

      const status = screen.getByText('Starting bridge...');
      expect(status).toHaveClass('bridge-status');
    });

    it('displays last error with error CSS class', () => {
      setupStore({ lastError: 'Connection timeout' });
      render(<TopBar />);

      const errorElement = screen.getByText('Connection timeout');
      expect(errorElement).toHaveClass('bridge-status');
      expect(errorElement).toHaveClass('bridge-status--error');
    });

    it('displays both bridge status and error simultaneously', () => {
      setupStore({
        bridgeStatus: 'Bridge running',
        lastError: 'WebSocket error',
      });
      render(<TopBar />);

      expect(screen.getByText('Bridge running')).toBeInTheDocument();
      expect(screen.getByText('WebSocket error')).toBeInTheDocument();
    });
  });

  // =========================================================================
  // Session Info Display Tests
  // =========================================================================

  describe('session info display', () => {
    it('displays "None" when no active session', () => {
      setupStore({ activeSessionId: null });
      render(<TopBar />);

      expect(screen.getByText('None')).toBeInTheDocument();
    });

    it('displays active session ID when set', () => {
      setupStore({ activeSessionId: 'my-session-123' });
      render(<TopBar />);

      expect(screen.getByText('my-session-123')).toBeInTheDocument();
    });

    it('displays "Active Session" label', () => {
      setupStore({ activeSessionId: 'test-session' });
      render(<TopBar />);

      expect(screen.getByText('Active Session')).toBeInTheDocument();
    });
  });

  // =========================================================================
  // Model Info Display Tests
  // =========================================================================

  describe('model info display', () => {
    it('displays model provider and id when stats available', () => {
      const stats = createStats({
        session_id: 'test-session',
        model: { provider: 'anthropic', id: 'claude-3-opus' },
      });
      setupStore({ activeSessionId: 'test-session', stats });
      render(<TopBar />);

      expect(screen.getByText('anthropic:claude-3-opus')).toBeInTheDocument();
    });

    it('does not display model info when no stats', () => {
      setupStore({ activeSessionId: 'test-session' });
      render(<TopBar />);

      expect(screen.queryByText('Model')).not.toBeInTheDocument();
    });

    it('does not display model info when no active session', () => {
      const stats = createStats({ session_id: 'other-session' });
      setupStore({ activeSessionId: null, stats });
      render(<TopBar />);

      expect(screen.queryByText(/anthropic/)).not.toBeInTheDocument();
    });
  });

  // =========================================================================
  // Stats Display Tests
  // =========================================================================

  describe('stats display', () => {
    it('displays streaming status as "Yes" when streaming', () => {
      const stats = createStats({
        session_id: 'test-session',
        is_streaming: true,
      });
      setupStore({ activeSessionId: 'test-session', stats });
      render(<TopBar />);

      expect(screen.getByText('Yes')).toBeInTheDocument();
    });

    it('displays streaming status as "No" when not streaming', () => {
      const stats = createStats({
        session_id: 'test-session',
        is_streaming: false,
      });
      setupStore({ activeSessionId: 'test-session', stats });
      render(<TopBar />);

      expect(screen.getByText('No')).toBeInTheDocument();
    });

    it('displays "Streaming" label when stats available', () => {
      const stats = createStats({ session_id: 'test-session' });
      setupStore({ activeSessionId: 'test-session', stats });
      render(<TopBar />);

      expect(screen.getByText('Streaming')).toBeInTheDocument();
    });
  });

  // =========================================================================
  // Title Display Tests
  // =========================================================================

  describe('title display', () => {
    it('displays default title when no custom title', () => {
      setupStore({ title: null });
      render(<TopBar />);

      expect(screen.getByText('Lemon Web UI')).toBeInTheDocument();
    });

    it('displays custom title when set', () => {
      setupStore({ title: 'My Custom Project' });
      render(<TopBar />);

      expect(screen.getByText('My Custom Project')).toBeInTheDocument();
    });

    it('displays Lemon badge', () => {
      setupStore();
      render(<TopBar />);

      expect(screen.getByText('Lemon')).toBeInTheDocument();
    });
  });

  // =========================================================================
  // Button Functionality Tests
  // =========================================================================

  describe('button functionality', () => {
    it('sends ping command when Ping button clicked', () => {
      const { mockSend } = setupStore();
      render(<TopBar />);

      fireEvent.click(screen.getByText('Ping'));

      expect(mockSend).toHaveBeenCalledWith({ type: 'ping' });
    });

    it('sends debug command when Debug button clicked', () => {
      const { mockSend } = setupStore();
      render(<TopBar />);

      fireEvent.click(screen.getByText('Debug'));

      expect(mockSend).toHaveBeenCalledWith({ type: 'debug' });
    });

    it('sends stats command with session_id when Stats button clicked', () => {
      const { mockSend } = setupStore({ activeSessionId: 'my-session' });
      render(<TopBar />);

      fireEvent.click(screen.getByText('Stats'));

      expect(mockSend).toHaveBeenCalledWith({
        type: 'stats',
        session_id: 'my-session',
      });
    });

    it('sends abort command with session_id when Abort button clicked', () => {
      const { mockSend } = setupStore({ activeSessionId: 'my-session' });
      render(<TopBar />);

      fireEvent.click(screen.getByText('Abort'));

      expect(mockSend).toHaveBeenCalledWith({
        type: 'abort',
        session_id: 'my-session',
      });
    });

    it('sends reset command with session_id when Reset button clicked', () => {
      const { mockSend } = setupStore({ activeSessionId: 'my-session' });
      render(<TopBar />);

      fireEvent.click(screen.getByText('Reset'));

      expect(mockSend).toHaveBeenCalledWith({
        type: 'reset',
        session_id: 'my-session',
      });
    });

    it('sends save command with session_id when Save button clicked', () => {
      const { mockSend } = setupStore({ activeSessionId: 'my-session' });
      render(<TopBar />);

      fireEvent.click(screen.getByText('Save'));

      expect(mockSend).toHaveBeenCalledWith({
        type: 'save',
        session_id: 'my-session',
      });
    });

    it('disables Stats button when no active session', () => {
      setupStore({ activeSessionId: null });
      render(<TopBar />);

      expect(screen.getByText('Stats')).toBeDisabled();
    });

    it('disables Abort button when no active session', () => {
      setupStore({ activeSessionId: null });
      render(<TopBar />);

      expect(screen.getByText('Abort')).toBeDisabled();
    });

    it('disables Reset button when no active session', () => {
      setupStore({ activeSessionId: null });
      render(<TopBar />);

      expect(screen.getByText('Reset')).toBeDisabled();
    });

    it('disables Save button when no active session', () => {
      setupStore({ activeSessionId: null });
      render(<TopBar />);

      expect(screen.getByText('Save')).toBeDisabled();
    });

    it('enables session buttons when active session exists', () => {
      setupStore({ activeSessionId: 'test-session' });
      render(<TopBar />);

      expect(screen.getByText('Stats')).not.toBeDisabled();
      expect(screen.getByText('Abort')).not.toBeDisabled();
      expect(screen.getByText('Reset')).not.toBeDisabled();
      expect(screen.getByText('Save')).not.toBeDisabled();
    });

    it('Ping and Debug buttons are always enabled', () => {
      setupStore({ activeSessionId: null });
      render(<TopBar />);

      expect(screen.getByText('Ping')).not.toBeDisabled();
      expect(screen.getByText('Debug')).not.toBeDisabled();
    });
  });

  // =========================================================================
  // Edge Cases and Integration Tests
  // =========================================================================

  describe('edge cases', () => {
    it('handles stats for different session than active (does not display)', () => {
      const stats = createStats({ session_id: 'different-session' });
      setupStore({ activeSessionId: 'active-session', stats });
      render(<TopBar />);

      // Model info should not be displayed since stats are for different session
      expect(screen.queryByText('Model')).not.toBeInTheDocument();
    });

    it('handles empty string bridge status', () => {
      setupStore({ bridgeStatus: '' });
      render(<TopBar />);

      // Empty string should not render the element
      const bridgeElements = document.querySelectorAll('.bridge-status');
      expect(bridgeElements.length).toBe(0);
    });

    it('handles very long session IDs', () => {
      const longId = 'very-long-session-id-' + 'x'.repeat(100);
      setupStore({ activeSessionId: longId });
      render(<TopBar />);

      expect(screen.getByText(longId)).toBeInTheDocument();
    });

    it('handles special characters in error messages', () => {
      setupStore({ lastError: '<script>alert("xss")</script>' });
      render(<TopBar />);

      // Should render as text, not execute
      expect(screen.getByText('<script>alert("xss")</script>')).toBeInTheDocument();
    });

    it('renders all sections in correct order', () => {
      const stats = createStats({ session_id: 'test-session' });
      setupStore({
        activeSessionId: 'test-session',
        stats,
        connectionState: 'connected',
        queueCount: 2,
        bridgeStatus: 'Running',
      });
      render(<TopBar />);

      const header = screen.getByRole('banner');
      expect(header).toHaveClass('top-bar');

      // Verify all main sections exist
      expect(header.querySelector('.top-bar__left')).toBeInTheDocument();
      expect(header.querySelector('.top-bar__center')).toBeInTheDocument();
      expect(header.querySelector('.top-bar__right')).toBeInTheDocument();
    });

    it('handles transition from connected to disconnected', () => {
      setupStore({ connectionState: 'connected' });
      const { rerender } = render(<TopBar />);

      expect(screen.getByText('Connected')).toBeInTheDocument();

      useLemonStore.setState((state) => ({
        connection: { ...state.connection, state: 'disconnected' },
      }));
      rerender(<TopBar />);

      expect(screen.getByText('Disconnected')).toBeInTheDocument();
    });
  });
});
