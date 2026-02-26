import { render, screen, within } from '@testing-library/react';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { StatusBar } from './StatusBar';
import { useLemonStore } from '../store/useLemonStore';
import type { SessionStats } from '@lemon-web/shared';

/**
 * Test helper to set up store state for StatusBar tests
 */
function setupStore(overrides: {
  status?: Record<string, string>;
  activeSessionId?: string | null;
  stats?: SessionStats;
} = {}) {
  useLemonStore.setState({
    ui: {
      requestsQueue: [],
      status: overrides.status ?? {},
      widgets: {},
      workingMessage: null,
      title: null,
      editorText: '',
    },
    connection: {
      state: 'connected',
      lastError: null,
      lastServerTime: undefined,
      bridgeStatus: null,
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
  });
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

/**
 * Reset store to default state after each test
 */
function resetStore() {
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
  });
}

describe('StatusBar', () => {
  beforeEach(() => {
    resetStore();
  });

  afterEach(() => {
    resetStore();
  });

  // =========================================================================
  // Basic Rendering Tests
  // =========================================================================

  describe('basic rendering', () => {
    it('renders the status bar container with correct CSS class', () => {
      setupStore();
      render(<StatusBar />);

      const statusBar = document.querySelector('.status-bar');
      expect(statusBar).toBeInTheDocument();
    });

    it('renders the status section with correct CSS class', () => {
      setupStore();
      render(<StatusBar />);

      const section = document.querySelector('.status-bar__section');
      expect(section).toBeInTheDocument();
    });

    it('renders the "Status" label', () => {
      setupStore();
      render(<StatusBar />);

      expect(screen.getByText('Status')).toBeInTheDocument();
    });

    it('applies status-label CSS class to the Status label', () => {
      setupStore();
      render(<StatusBar />);

      const label = screen.getByText('Status');
      expect(label).toHaveClass('status-label');
    });
  });

  // =========================================================================
  // Empty State Tests
  // =========================================================================

  describe('empty state handling', () => {
    it('displays "No status updates yet." when statusMap is empty', () => {
      setupStore({ status: {} });
      render(<StatusBar />);

      expect(screen.getByText('No status updates yet.')).toBeInTheDocument();
    });

    it('applies muted CSS class to empty state message', () => {
      setupStore({ status: {} });
      render(<StatusBar />);

      const emptyMessage = screen.getByText('No status updates yet.');
      expect(emptyMessage).toHaveClass('muted');
    });

    it('does not render any status pills when statusMap is empty', () => {
      setupStore({ status: {} });
      render(<StatusBar />);

      const pills = document.querySelectorAll('.status-pill');
      // The only pills should be from stats section if present
      expect(pills.length).toBe(0);
    });

    it('handles undefined status gracefully (defaults to empty object)', () => {
      setupStore();
      render(<StatusBar />);

      // Should show empty state message
      expect(screen.getByText('No status updates yet.')).toBeInTheDocument();
    });
  });

  // =========================================================================
  // Status Map Rendering Tests
  // =========================================================================

  describe('status map rendering', () => {
    it('renders a single status entry as a pill', () => {
      setupStore({ status: { agent: 'running' } });
      render(<StatusBar />);

      expect(screen.getByText('agent: running')).toBeInTheDocument();
    });

    it('applies status-pill CSS class to status entries', () => {
      setupStore({ status: { agent: 'running' } });
      render(<StatusBar />);

      const pill = screen.getByText('agent: running');
      expect(pill).toHaveClass('status-pill');
    });

    it('renders multiple status entries as separate pills', () => {
      setupStore({
        status: {
          agent: 'running',
          model: 'claude-3-opus',
          phase: 'thinking',
        },
      });
      render(<StatusBar />);

      expect(screen.getByText('agent: running')).toBeInTheDocument();
      expect(screen.getByText('model: claude-3-opus')).toBeInTheDocument();
      expect(screen.getByText('phase: thinking')).toBeInTheDocument();
    });

    it('does not display empty state message when statuses exist', () => {
      setupStore({ status: { agent: 'running' } });
      render(<StatusBar />);

      expect(screen.queryByText('No status updates yet.')).not.toBeInTheDocument();
    });

    it('renders status entries with colon separator format', () => {
      setupStore({ status: { task: 'processing' } });
      render(<StatusBar />);

      const pill = screen.getByText('task: processing');
      expect(pill.textContent).toBe('task: processing');
    });

    it('handles status keys with special characters', () => {
      setupStore({ status: { 'my-key': 'value', my_key2: 'value2' } });
      render(<StatusBar />);

      expect(screen.getByText('my-key: value')).toBeInTheDocument();
      expect(screen.getByText('my_key2: value2')).toBeInTheDocument();
    });

    it('handles status values with special characters', () => {
      setupStore({ status: { path: '/home/user/project' } });
      render(<StatusBar />);

      expect(screen.getByText('path: /home/user/project')).toBeInTheDocument();
    });

    it('handles very long status keys and values', () => {
      const longKey = 'very_long_key_name_' + 'x'.repeat(50);
      const longValue = 'very_long_value_' + 'y'.repeat(100);
      setupStore({ status: { [longKey]: longValue } });
      render(<StatusBar />);

      expect(screen.getByText(`${longKey}: ${longValue}`)).toBeInTheDocument();
    });

    it('handles empty string status values', () => {
      setupStore({ status: { empty: '' } });
      render(<StatusBar />);

      expect(screen.getByText('empty:')).toBeInTheDocument();
    });

    it('assigns unique keys to each status pill', () => {
      setupStore({
        status: {
          key1: 'value1',
          key2: 'value2',
          key3: 'value3',
        },
      });
      render(<StatusBar />);

      const pills = document.querySelectorAll('.status-pill');
      // 3 status pills
      expect(pills.length).toBe(3);
    });
  });

  // =========================================================================
  // Session Stats Display Tests
  // =========================================================================

  describe('session stats display', () => {
    it('displays turn count when stats available for active session', () => {
      const stats = createStats({ session_id: 'test-session', turn_count: 7 });
      setupStore({ activeSessionId: 'test-session', stats });
      render(<StatusBar />);

      expect(screen.getByText('Turns: 7')).toBeInTheDocument();
    });

    it('displays message count when stats available for active session', () => {
      const stats = createStats({ session_id: 'test-session', message_count: 25 });
      setupStore({ activeSessionId: 'test-session', stats });
      render(<StatusBar />);

      expect(screen.getByText('Messages: 25')).toBeInTheDocument();
    });

    it('displays CWD when stats available for active session', () => {
      const stats = createStats({ session_id: 'test-session', cwd: '/my/project/path' });
      setupStore({ activeSessionId: 'test-session', stats });
      render(<StatusBar />);

      expect(screen.getByText('CWD: /my/project/path')).toBeInTheDocument();
    });

    it('applies status-pill CSS class to stats pills', () => {
      const stats = createStats({ session_id: 'test-session' });
      setupStore({ activeSessionId: 'test-session', stats });
      render(<StatusBar />);

      const turnsPill = screen.getByText(/Turns:/);
      const messagesPill = screen.getByText(/Messages:/);
      const cwdPill = screen.getByText(/CWD:/);

      expect(turnsPill).toHaveClass('status-pill');
      expect(messagesPill).toHaveClass('status-pill');
      expect(cwdPill).toHaveClass('status-pill');
    });

    it('renders stats in a separate status-bar__section', () => {
      const stats = createStats({ session_id: 'test-session' });
      setupStore({ activeSessionId: 'test-session', stats });
      render(<StatusBar />);

      const sections = document.querySelectorAll('.status-bar__section');
      // Two sections: status section and stats section
      expect(sections.length).toBe(2);
    });

    it('does not display stats section when no active session', () => {
      const stats = createStats({ session_id: 'test-session' });
      setupStore({ activeSessionId: null, stats });
      render(<StatusBar />);

      expect(screen.queryByText(/Turns:/)).not.toBeInTheDocument();
      expect(screen.queryByText(/Messages:/)).not.toBeInTheDocument();
      expect(screen.queryByText(/CWD:/)).not.toBeInTheDocument();
    });

    it('does not display stats section when stats not available for active session', () => {
      setupStore({ activeSessionId: 'test-session' });
      render(<StatusBar />);

      expect(screen.queryByText(/Turns:/)).not.toBeInTheDocument();
      expect(screen.queryByText(/Messages:/)).not.toBeInTheDocument();
      expect(screen.queryByText(/CWD:/)).not.toBeInTheDocument();
    });

    it('does not display stats when stats belong to different session than active', () => {
      const stats = createStats({ session_id: 'other-session' });
      setupStore({ activeSessionId: 'active-session', stats });
      render(<StatusBar />);

      expect(screen.queryByText(/Turns:/)).not.toBeInTheDocument();
    });

    it('handles zero values for turn and message counts', () => {
      const stats = createStats({
        session_id: 'test-session',
        turn_count: 0,
        message_count: 0,
      });
      setupStore({ activeSessionId: 'test-session', stats });
      render(<StatusBar />);

      expect(screen.getByText('Turns: 0')).toBeInTheDocument();
      expect(screen.getByText('Messages: 0')).toBeInTheDocument();
    });

    it('handles large numbers for turn and message counts', () => {
      const stats = createStats({
        session_id: 'test-session',
        turn_count: 999999,
        message_count: 1234567,
      });
      setupStore({ activeSessionId: 'test-session', stats });
      render(<StatusBar />);

      expect(screen.getByText('Turns: 999999')).toBeInTheDocument();
      expect(screen.getByText('Messages: 1234567')).toBeInTheDocument();
    });

    it('handles CWD with spaces and special characters', () => {
      const stats = createStats({
        session_id: 'test-session',
        cwd: '/path/with spaces/and-special_chars!@#$',
      });
      setupStore({ activeSessionId: 'test-session', stats });
      render(<StatusBar />);

      expect(screen.getByText('CWD: /path/with spaces/and-special_chars!@#$')).toBeInTheDocument();
    });
  });

  // =========================================================================
  // Combined Status and Stats Tests
  // =========================================================================

  describe('combined status and stats display', () => {
    it('displays both status entries and session stats simultaneously', () => {
      const stats = createStats({ session_id: 'test-session' });
      setupStore({
        status: { agent: 'running', phase: 'thinking' },
        activeSessionId: 'test-session',
        stats,
      });
      render(<StatusBar />);

      // Status entries
      expect(screen.getByText('agent: running')).toBeInTheDocument();
      expect(screen.getByText('phase: thinking')).toBeInTheDocument();
      // Stats entries
      expect(screen.getByText('Turns: 5')).toBeInTheDocument();
      expect(screen.getByText('Messages: 10')).toBeInTheDocument();
      expect(screen.getByText('CWD: /test/path')).toBeInTheDocument();
    });

    it('renders status section before stats section', () => {
      const stats = createStats({ session_id: 'test-session' });
      setupStore({
        status: { agent: 'running' },
        activeSessionId: 'test-session',
        stats,
      });
      render(<StatusBar />);

      const sections = document.querySelectorAll('.status-bar__section');
      expect(sections.length).toBe(2);

      // First section should contain status label
      expect(within(sections[0]).getByText('Status')).toBeInTheDocument();
      // Second section should contain stats
      expect(within(sections[1]).getByText(/Turns:/)).toBeInTheDocument();
    });

    it('shows empty state in status section while displaying stats', () => {
      const stats = createStats({ session_id: 'test-session' });
      setupStore({
        status: {},
        activeSessionId: 'test-session',
        stats,
      });
      render(<StatusBar />);

      // Empty state message
      expect(screen.getByText('No status updates yet.')).toBeInTheDocument();
      // Stats should still be visible
      expect(screen.getByText('Turns: 5')).toBeInTheDocument();
    });
  });

  // =========================================================================
  // Status Updates Tests
  // =========================================================================

  describe('status updates', () => {
    it('updates display when status map changes', () => {
      setupStore({ status: { agent: 'starting' } });
      const { rerender } = render(<StatusBar />);

      expect(screen.getByText('agent: starting')).toBeInTheDocument();

      // Update the store
      useLemonStore.setState((state) => ({
        ui: { ...state.ui, status: { agent: 'running' } },
      }));
      rerender(<StatusBar />);

      expect(screen.getByText('agent: running')).toBeInTheDocument();
      expect(screen.queryByText('agent: starting')).not.toBeInTheDocument();
    });

    it('adds new status entries dynamically', () => {
      setupStore({ status: { agent: 'running' } });
      const { rerender } = render(<StatusBar />);

      expect(screen.getByText('agent: running')).toBeInTheDocument();
      expect(screen.queryByText('phase: thinking')).not.toBeInTheDocument();

      // Add new status
      useLemonStore.setState((state) => ({
        ui: { ...state.ui, status: { ...state.ui.status, phase: 'thinking' } },
      }));
      rerender(<StatusBar />);

      expect(screen.getByText('agent: running')).toBeInTheDocument();
      expect(screen.getByText('phase: thinking')).toBeInTheDocument();
    });

    it('removes status entries dynamically', () => {
      setupStore({ status: { agent: 'running', phase: 'thinking' } });
      const { rerender } = render(<StatusBar />);

      expect(screen.getByText('agent: running')).toBeInTheDocument();
      expect(screen.getByText('phase: thinking')).toBeInTheDocument();

      // Remove a status
      useLemonStore.setState((state) => ({
        ui: { ...state.ui, status: { agent: 'running' } },
      }));
      rerender(<StatusBar />);

      expect(screen.getByText('agent: running')).toBeInTheDocument();
      expect(screen.queryByText('phase: thinking')).not.toBeInTheDocument();
    });

    it('transitions from empty state to populated state', () => {
      setupStore({ status: {} });
      const { rerender } = render(<StatusBar />);

      expect(screen.getByText('No status updates yet.')).toBeInTheDocument();

      // Add a status
      useLemonStore.setState((state) => ({
        ui: { ...state.ui, status: { agent: 'running' } },
      }));
      rerender(<StatusBar />);

      expect(screen.queryByText('No status updates yet.')).not.toBeInTheDocument();
      expect(screen.getByText('agent: running')).toBeInTheDocument();
    });

    it('transitions from populated state to empty state', () => {
      setupStore({ status: { agent: 'running' } });
      const { rerender } = render(<StatusBar />);

      expect(screen.getByText('agent: running')).toBeInTheDocument();

      // Clear all statuses
      useLemonStore.setState((state) => ({
        ui: { ...state.ui, status: {} },
      }));
      rerender(<StatusBar />);

      expect(screen.getByText('No status updates yet.')).toBeInTheDocument();
      expect(screen.queryByText('agent: running')).not.toBeInTheDocument();
    });

    it('updates stats display when active session changes', () => {
      const stats1 = createStats({ session_id: 'session-1', turn_count: 5 });
      const stats2 = createStats({ session_id: 'session-2', turn_count: 10 });

      useLemonStore.setState({
        ui: {
          requestsQueue: [],
          status: {},
          widgets: {},
          workingMessage: null,
          title: null,
          editorText: '',
        },
        sessions: {
          running: {},
          saved: [],
          activeSessionId: 'session-1',
          primarySessionId: null,
        },
        statsBySession: {
          'session-1': stats1,
          'session-2': stats2,
        },
      });

      const { rerender } = render(<StatusBar />);
      expect(screen.getByText('Turns: 5')).toBeInTheDocument();

      // Switch active session
      useLemonStore.setState((state) => ({
        sessions: { ...state.sessions, activeSessionId: 'session-2' },
      }));
      rerender(<StatusBar />);

      expect(screen.getByText('Turns: 10')).toBeInTheDocument();
      expect(screen.queryByText('Turns: 5')).not.toBeInTheDocument();
    });

    it('hides stats when active session is cleared', () => {
      const stats = createStats({ session_id: 'test-session' });
      setupStore({ activeSessionId: 'test-session', stats });
      const { rerender } = render(<StatusBar />);

      expect(screen.getByText('Turns: 5')).toBeInTheDocument();

      // Clear active session
      useLemonStore.setState((state) => ({
        sessions: { ...state.sessions, activeSessionId: null },
      }));
      rerender(<StatusBar />);

      expect(screen.queryByText(/Turns:/)).not.toBeInTheDocument();
    });

    it('updates stats values dynamically', () => {
      const stats = createStats({ session_id: 'test-session', turn_count: 5, message_count: 10 });
      setupStore({ activeSessionId: 'test-session', stats });
      const { rerender } = render(<StatusBar />);

      expect(screen.getByText('Turns: 5')).toBeInTheDocument();
      expect(screen.getByText('Messages: 10')).toBeInTheDocument();

      // Update stats
      const updatedStats = createStats({
        session_id: 'test-session',
        turn_count: 6,
        message_count: 12,
      });
      useLemonStore.setState((state) => ({
        statsBySession: { ...state.statsBySession, 'test-session': updatedStats },
      }));
      rerender(<StatusBar />);

      expect(screen.getByText('Turns: 6')).toBeInTheDocument();
      expect(screen.getByText('Messages: 12')).toBeInTheDocument();
    });
  });

  // =========================================================================
  // Multiple Status Entries Tests
  // =========================================================================

  describe('multiple status entries', () => {
    it('renders many status entries correctly', () => {
      const manyStatuses: Record<string, string> = {};
      for (let i = 0; i < 10; i++) {
        manyStatuses[`key${i}`] = `value${i}`;
      }
      setupStore({ status: manyStatuses });
      render(<StatusBar />);

      for (let i = 0; i < 10; i++) {
        expect(screen.getByText(`key${i}: value${i}`)).toBeInTheDocument();
      }
    });

    it('preserves all status entries without duplication', () => {
      setupStore({
        status: {
          a: '1',
          b: '2',
          c: '3',
          d: '4',
          e: '5',
        },
      });
      render(<StatusBar />);

      const pills = document.querySelectorAll('.status-pill');
      expect(pills.length).toBe(5);
    });

    it('handles status entries with similar keys', () => {
      setupStore({
        status: {
          status: 'active',
          status_code: '200',
          status_message: 'OK',
        },
      });
      render(<StatusBar />);

      expect(screen.getByText('status: active')).toBeInTheDocument();
      expect(screen.getByText('status_code: 200')).toBeInTheDocument();
      expect(screen.getByText('status_message: OK')).toBeInTheDocument();
    });

    it('handles status entries with similar values', () => {
      setupStore({
        status: {
          key1: 'running',
          key2: 'running',
          key3: 'running',
        },
      });
      render(<StatusBar />);

      expect(screen.getByText('key1: running')).toBeInTheDocument();
      expect(screen.getByText('key2: running')).toBeInTheDocument();
      expect(screen.getByText('key3: running')).toBeInTheDocument();
    });
  });

  // =========================================================================
  // CSS and Styling Tests
  // =========================================================================

  describe('CSS and styling', () => {
    it('status-bar container is the root element', () => {
      setupStore();
      const { container } = render(<StatusBar />);

      expect(container.firstChild).toHaveClass('status-bar');
    });

    it('each status pill has exactly the status-pill class', () => {
      setupStore({ status: { key: 'value' } });
      render(<StatusBar />);

      const pill = screen.getByText('key: value');
      expect(pill.className).toBe('status-pill');
    });

    it('stats pills maintain consistent styling with status pills', () => {
      const stats = createStats({ session_id: 'test-session' });
      setupStore({
        status: { agent: 'running' },
        activeSessionId: 'test-session',
        stats,
      });
      render(<StatusBar />);

      const statusPill = screen.getByText('agent: running');
      const turnsPill = screen.getByText('Turns: 5');

      // Both should have the same base class
      expect(statusPill).toHaveClass('status-pill');
      expect(turnsPill).toHaveClass('status-pill');
    });

    it('sections are siblings within status-bar', () => {
      const stats = createStats({ session_id: 'test-session' });
      setupStore({
        status: { agent: 'running' },
        activeSessionId: 'test-session',
        stats,
      });
      render(<StatusBar />);

      const statusBar = document.querySelector('.status-bar');
      const sections = statusBar?.querySelectorAll('.status-bar__section');

      expect(sections?.length).toBe(2);
      // Both sections should be direct children
      sections?.forEach((section) => {
        expect(section.parentElement).toBe(statusBar);
      });
    });
  });

  // =========================================================================
  // Edge Cases Tests
  // =========================================================================

  describe('edge cases', () => {
    it('handles status key that looks like HTML', () => {
      setupStore({ status: { '<script>': 'alert("xss")' } });
      render(<StatusBar />);

      // Should render as text, not execute
      expect(screen.getByText('<script>: alert("xss")')).toBeInTheDocument();
    });

    it('handles status value that looks like HTML', () => {
      setupStore({ status: { key: '<b>bold</b>' } });
      render(<StatusBar />);

      // Should render as text
      const pill = screen.getByText('key: <b>bold</b>');
      expect(pill.innerHTML).not.toContain('<b>');
    });

    it('handles unicode characters in status keys and values', () => {
      setupStore({ status: { emoji: '🚀', japanese: '日本語' } });
      render(<StatusBar />);

      expect(screen.getByText('emoji: 🚀')).toBeInTheDocument();
      expect(screen.getByText('japanese: 日本語')).toBeInTheDocument();
    });

    it('handles very long CWD paths gracefully', () => {
      const longPath = '/very' + '/deeply'.repeat(50) + '/nested/path';
      const stats = createStats({ session_id: 'test-session', cwd: longPath });
      setupStore({ activeSessionId: 'test-session', stats });
      render(<StatusBar />);

      expect(screen.getByText(`CWD: ${longPath}`)).toBeInTheDocument();
    });

    it('handles whitespace-only status values', () => {
      setupStore({ status: { spaces: '   ', tabs: '\t\t' } });
      render(<StatusBar />);

      // Should render, even if visually empty
      const pills = document.querySelectorAll('.status-pill');
      expect(pills.length).toBe(2);
    });

    it('handles numeric-like status keys', () => {
      setupStore({ status: { '123': 'numeric', '0': 'zero' } });
      render(<StatusBar />);

      expect(screen.getByText('123: numeric')).toBeInTheDocument();
      expect(screen.getByText('0: zero')).toBeInTheDocument();
    });
  });

  // =========================================================================
  // Memoization Tests
  // =========================================================================

  describe('memoization behavior', () => {
    it('recomputes status entries when statusMap object changes', () => {
      setupStore({ status: { a: '1' } });
      const { rerender } = render(<StatusBar />);

      expect(screen.getByText('a: 1')).toBeInTheDocument();

      // Change to completely new object
      useLemonStore.setState((state) => ({
        ui: { ...state.ui, status: { b: '2' } },
      }));
      rerender(<StatusBar />);

      expect(screen.queryByText('a: 1')).not.toBeInTheDocument();
      expect(screen.getByText('b: 2')).toBeInTheDocument();
    });

    it('maintains stable rendering with same status values', () => {
      setupStore({ status: { key: 'value' } });
      const { rerender } = render(<StatusBar />);

      const initialPill = screen.getByText('key: value');
      expect(initialPill).toBeInTheDocument();

      // Rerender with same store state
      rerender(<StatusBar />);

      const afterPill = screen.getByText('key: value');
      expect(afterPill).toBeInTheDocument();
    });
  });
});
