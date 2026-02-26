import { act, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { Sidebar } from './Sidebar';
import { useLemonStore, type LemonState } from '../store/useLemonStore';
import type {
  RunningSessionInfo,
  SessionSummary,
  ModelsListMessage,
  SessionStats,
} from '@lemon-web/shared';

// ============================================================================
// Test Fixtures
// ============================================================================

function createRunningSession(overrides: Partial<RunningSessionInfo> = {}): RunningSessionInfo {
  return {
    session_id: 'session-1',
    cwd: '/home/user/project',
    is_streaming: false,
    ...overrides,
  };
}

function createSavedSession(overrides: Partial<SessionSummary> = {}): SessionSummary {
  return {
    id: 'saved-session-1',
    path: '/home/user/.lemon/sessions/saved-session-1.jsonl',
    timestamp: Date.now(),
    cwd: '/home/user/project',
    ...overrides,
  };
}

function createProviders(): ModelsListMessage['providers'] {
  return [
    {
      id: 'anthropic',
      models: [
        { id: 'claude-sonnet-4-20250514', name: 'Claude Sonnet 4' },
        { id: 'claude-opus-4-20250514', name: 'Claude Opus 4' },
      ],
    },
    {
      id: 'openai',
      models: [
        { id: 'gpt-4', name: 'GPT-4' },
        { id: 'gpt-4-turbo', name: 'GPT-4 Turbo' },
      ],
    },
  ];
}

function createSessionStats(overrides: Partial<SessionStats> = {}): SessionStats {
  return {
    session_id: 'session-1',
    message_count: 5,
    turn_count: 2,
    is_streaming: false,
    cwd: '/home/user/project',
    model: { provider: 'anthropic', id: 'claude-sonnet-4-20250514' },
    thinking_level: null,
    ...overrides,
  };
}

// ============================================================================
// Store Setup Helpers
// ============================================================================

function getInitialState(): Partial<LemonState> {
  return {
    sessions: {
      running: {},
      saved: [],
      activeSessionId: null,
      primarySessionId: null,
    },
    models: [],
    statsBySession: {},
    debugLog: [],
    config: {
      claude_skip_permissions: true,
      codex_auto_approve: false,
    },
    ui: {
      requestsQueue: [],
      status: {},
      widgets: {},
      workingMessage: null,
      title: null,
      editorText: '',
    },
    autoActivateNextSession: false,
  };
}

function setupStore(overrides: Partial<LemonState> = {}) {
  const mockSend = vi.fn();
  const mockSetAutoActivateNextSession = vi.fn();
  const mockSetConfig = vi.fn();

  useLemonStore.setState({
    ...getInitialState(),
    send: mockSend,
    setAutoActivateNextSession: mockSetAutoActivateNextSession,
    setConfig: mockSetConfig,
    ...overrides,
  } as LemonState);

  return { mockSend, mockSetAutoActivateNextSession, mockSetConfig };
}

// ============================================================================
// Tests
// ============================================================================

describe('Sidebar', () => {
  beforeEach(() => {
    setupStore();
  });

  describe('Session List Rendering', () => {
    it('renders empty state when no running sessions', () => {
      render(<Sidebar />);
      expect(screen.getByText('No running sessions.')).toBeInTheDocument();
    });

    it('renders running sessions list', () => {
      setupStore({
        sessions: {
          running: {
            'session-1': createRunningSession({ session_id: 'session-1', cwd: '/project/a' }),
            'session-2': createRunningSession({ session_id: 'session-2', cwd: '/project/b' }),
          },
          saved: [],
          activeSessionId: null,
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      expect(screen.getByText('session-1')).toBeInTheDocument();
      expect(screen.getByText('session-2')).toBeInTheDocument();
      expect(screen.getByText('/project/a')).toBeInTheDocument();
      expect(screen.getByText('/project/b')).toBeInTheDocument();
    });

    it('highlights active session with list-item--active class', () => {
      setupStore({
        sessions: {
          running: {
            'session-1': createRunningSession({ session_id: 'session-1' }),
            'session-2': createRunningSession({ session_id: 'session-2' }),
          },
          saved: [],
          activeSessionId: 'session-1',
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      const session1Item = screen.getByText('session-1').closest('.list-item');
      const session2Item = screen.getByText('session-2').closest('.list-item');

      expect(session1Item).toHaveClass('list-item--active');
      expect(session2Item).not.toHaveClass('list-item--active');
    });

    it('shows session cwd as metadata', () => {
      setupStore({
        sessions: {
          running: {
            'session-1': createRunningSession({ cwd: '/my/special/project' }),
          },
          saved: [],
          activeSessionId: null,
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      expect(screen.getByText('/my/special/project')).toBeInTheDocument();
    });
  });

  describe('Session Selection', () => {
    it('calls send with set_active_session when Activate button clicked', async () => {
      const { mockSend } = setupStore({
        sessions: {
          running: {
            'session-1': createRunningSession({ session_id: 'session-1' }),
          },
          saved: [],
          activeSessionId: null,
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      const activateBtn = screen.getByRole('button', { name: 'Activate' });
      await userEvent.click(activateBtn);

      expect(mockSend).toHaveBeenCalledWith({
        type: 'set_active_session',
        session_id: 'session-1',
      });
    });

    it('calls send with list_running_sessions when Refresh clicked', async () => {
      const { mockSend } = setupStore();

      render(<Sidebar />);

      const sessionsSection = screen.getByText('Sessions').closest('.sidebar-section');
      const refreshBtn = within(sessionsSection!).getByRole('button', { name: 'Refresh' });
      await userEvent.click(refreshBtn);

      expect(mockSend).toHaveBeenCalledWith({ type: 'list_running_sessions' });
    });
  });

  describe('New Session Creation Form', () => {
    it('toggles new session form visibility with New/Close button', async () => {
      render(<Sidebar />);

      // Initially hidden
      expect(screen.queryByLabelText('CWD')).not.toBeInTheDocument();

      // Click "New" to show form
      await userEvent.click(screen.getByRole('button', { name: 'New' }));
      expect(screen.getByLabelText('CWD')).toBeInTheDocument();

      // Button text changes to "Close"
      expect(screen.getByRole('button', { name: 'Close' })).toBeInTheDocument();

      // Click "Close" to hide form
      await userEvent.click(screen.getByRole('button', { name: 'Close' }));
      expect(screen.queryByLabelText('CWD')).not.toBeInTheDocument();
    });

    it('renders CWD input field', async () => {
      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const cwdInput = screen.getByLabelText('CWD');
      expect(cwdInput).toBeInTheDocument();
      expect(cwdInput).toHaveAttribute('placeholder', '/path/to/project');
    });

    it('renders system prompt textarea', async () => {
      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const textarea = screen.getByLabelText('System Prompt');
      expect(textarea).toBeInTheDocument();
      expect(textarea).toHaveAttribute('placeholder', 'Leave empty for default (same as TUI).');
    });

    it('renders session file input', async () => {
      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const sessionFileInput = screen.getByLabelText('Session File');
      expect(sessionFileInput).toBeInTheDocument();
      expect(sessionFileInput).toHaveAttribute('placeholder', '/path/to/session.jsonl');
    });

    it('renders parent session dropdown', async () => {
      setupStore({
        sessions: {
          running: {
            'session-1': createRunningSession({ session_id: 'session-1' }),
            'session-2': createRunningSession({ session_id: 'session-2' }),
          },
          saved: [],
          activeSessionId: null,
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const parentSelect = screen.getByLabelText('Parent Session');
      expect(parentSelect).toBeInTheDocument();
      expect(within(parentSelect).getByRole('option', { name: 'None' })).toBeInTheDocument();
      expect(within(parentSelect).getByRole('option', { name: 'session-1' })).toBeInTheDocument();
      expect(within(parentSelect).getByRole('option', { name: 'session-2' })).toBeInTheDocument();
    });

    it('renders auto-activate checkbox', async () => {
      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const checkbox = screen.getByLabelText('Auto-activate new session');
      expect(checkbox).toBeInTheDocument();
      expect(checkbox).toBeChecked(); // default is true
    });

    it('renders Start Session button', async () => {
      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      expect(screen.getByRole('button', { name: 'Start Session' })).toBeInTheDocument();
    });

    it('submits form with correct data when Start Session clicked', async () => {
      const { mockSend, mockSetAutoActivateNextSession } = setupStore({
        models: createProviders(),
      });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      // Fill out form
      const cwdInput = screen.getByLabelText('CWD');
      await userEvent.clear(cwdInput);
      await userEvent.type(cwdInput, '/my/project');

      // Submit
      await userEvent.click(screen.getByRole('button', { name: 'Start Session' }));

      expect(mockSetAutoActivateNextSession).toHaveBeenCalledWith(true);
      expect(mockSend).toHaveBeenCalledWith({
        type: 'start_session',
        cwd: '/my/project',
        model: 'anthropic:claude-sonnet-4-20250514',
        system_prompt: undefined,
        session_file: undefined,
        parent_session: undefined,
      });
    });

    it('prevents default form submission behavior', async () => {
      const { mockSend } = setupStore();
      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const form = document.querySelector('.panel');
      const submitEvent = new Event('submit', { bubbles: true, cancelable: true });
      form?.dispatchEvent(submitEvent);

      // The page should not reload - we can verify send was called
      // (this is a basic check that preventDefault was called)
      expect(mockSend).toHaveBeenCalled();
    });
  });

  describe('Model/Provider Selection Dropdowns', () => {
    it('shows model text input when no providers available', async () => {
      setupStore({ models: [] });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      // Should show text input for model spec, not dropdowns
      const modelInput = screen.getByLabelText('Model');
      expect(modelInput.tagName).toBe('INPUT');
      expect(modelInput).toHaveAttribute('placeholder', 'provider:model_id');
    });

    it('shows provider and model dropdowns when providers available', async () => {
      setupStore({ models: createProviders() });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      expect(screen.getByLabelText('Provider')).toBeInTheDocument();
      expect(screen.getByLabelText('Model')).toBeInTheDocument();
    });

    it('populates provider dropdown with available providers', async () => {
      setupStore({ models: createProviders() });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const providerSelect = screen.getByLabelText('Provider');
      expect(within(providerSelect).getByRole('option', { name: 'anthropic' })).toBeInTheDocument();
      expect(within(providerSelect).getByRole('option', { name: 'openai' })).toBeInTheDocument();
    });

    it('populates model dropdown based on selected provider', async () => {
      setupStore({ models: createProviders() });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const modelSelect = screen.getByLabelText('Model');

      // Default provider is anthropic, so should show anthropic models
      expect(within(modelSelect).getByRole('option', { name: /claude-sonnet-4/ })).toBeInTheDocument();
      expect(within(modelSelect).getByRole('option', { name: /claude-opus-4/ })).toBeInTheDocument();
    });

    it('updates model options when provider changes', async () => {
      setupStore({ models: createProviders() });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      // Change provider to openai
      const providerSelect = screen.getByLabelText('Provider');
      await userEvent.selectOptions(providerSelect, 'openai');

      // Model dropdown should now show OpenAI models
      const modelSelect = screen.getByLabelText('Model');
      expect(within(modelSelect).getByRole('option', { name: /gpt-4 — GPT-4/ })).toBeInTheDocument();
      expect(within(modelSelect).getByRole('option', { name: /gpt-4-turbo — GPT-4 Turbo/ })).toBeInTheDocument();
    });

    it('displays model name alongside id when available', async () => {
      setupStore({ models: createProviders() });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const modelSelect = screen.getByLabelText('Model');
      // Format is "id - name" when name is provided
      expect(within(modelSelect).getByRole('option', { name: 'claude-sonnet-4-20250514 — Claude Sonnet 4' })).toBeInTheDocument();
    });
  });

  describe('CWD Input and Suggestions', () => {
    it('populates cwd suggestions from running sessions', async () => {
      setupStore({
        sessions: {
          running: {
            'session-1': createRunningSession({ session_id: 'session-1', cwd: '/project/alpha' }),
            'session-2': createRunningSession({ session_id: 'session-2', cwd: '/project/beta' }),
          },
          saved: [],
          activeSessionId: null,
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const datalist = document.getElementById('cwd-suggestions');
      expect(datalist).toBeInTheDocument();

      const options = datalist?.querySelectorAll('option');
      const values = Array.from(options || []).map((opt) => opt.getAttribute('value'));

      expect(values).toContain('/project/alpha');
      expect(values).toContain('/project/beta');
    });

    it('populates cwd suggestions from saved sessions', async () => {
      setupStore({
        sessions: {
          running: {},
          saved: [
            createSavedSession({ id: 'saved-1', path: '/home/user/.lemon/sessions/saved-1.jsonl', cwd: '/saved/project1' }),
            createSavedSession({ id: 'saved-2', path: '/home/user/.lemon/sessions/saved-2.jsonl', cwd: '/saved/project2' }),
          ],
          activeSessionId: null,
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const datalist = document.getElementById('cwd-suggestions');
      const options = datalist?.querySelectorAll('option');
      const values = Array.from(options || []).map((opt) => opt.getAttribute('value'));

      expect(values).toContain('/saved/project1');
      expect(values).toContain('/saved/project2');
    });

    it('deduplicates cwd suggestions', async () => {
      setupStore({
        sessions: {
          running: {
            'session-1': createRunningSession({ cwd: '/common/project' }),
          },
          saved: [createSavedSession({ cwd: '/common/project' })],
          activeSessionId: null,
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const datalist = document.getElementById('cwd-suggestions');
      const options = datalist?.querySelectorAll('option');
      const values = Array.from(options || []).map((opt) => opt.getAttribute('value'));

      // Should only appear once
      expect(values.filter((v) => v === '/common/project')).toHaveLength(1);
    });

    it('prioritizes active session cwd in suggestions', async () => {
      setupStore({
        sessions: {
          running: {
            'session-1': createRunningSession({ session_id: 'session-1', cwd: '/active/cwd' }),
            'session-2': createRunningSession({ session_id: 'session-2', cwd: '/other/cwd' }),
          },
          saved: [],
          activeSessionId: 'session-1',
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const datalist = document.getElementById('cwd-suggestions');
      const options = datalist?.querySelectorAll('option');
      const values = Array.from(options || []).map((opt) => opt.getAttribute('value'));

      // Active session's cwd should be first
      expect(values[0]).toBe('/active/cwd');
    });

    it('does not render datalist when no suggestions available', async () => {
      setupStore({
        sessions: {
          running: {},
          saved: [],
          activeSessionId: null,
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const datalist = document.getElementById('cwd-suggestions');
      expect(datalist).not.toBeInTheDocument();
    });
  });

  describe('Session File Suggestions', () => {
    it('populates session file suggestions from saved sessions', async () => {
      setupStore({
        sessions: {
          running: {},
          saved: [
            createSavedSession({ id: 'saved-1', path: '/home/.lemon/session1.jsonl' }),
            createSavedSession({ id: 'saved-2', path: '/home/.lemon/session2.jsonl' }),
          ],
          activeSessionId: null,
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const datalist = document.getElementById('session-file-suggestions');
      expect(datalist).toBeInTheDocument();

      const options = datalist?.querySelectorAll('option');
      const values = Array.from(options || []).map((opt) => opt.getAttribute('value'));

      expect(values).toContain('/home/.lemon/session1.jsonl');
      expect(values).toContain('/home/.lemon/session2.jsonl');
    });

    it('does not render session file datalist when no saved sessions', async () => {
      setupStore({
        sessions: {
          running: {},
          saved: [],
          activeSessionId: null,
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const datalist = document.getElementById('session-file-suggestions');
      expect(datalist).not.toBeInTheDocument();
    });
  });

  describe('Auto-activate Toggle', () => {
    it('checkbox is checked by default', async () => {
      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const checkbox = screen.getByLabelText('Auto-activate new session');
      expect(checkbox).toBeChecked();
    });

    it('toggles checkbox state when clicked', async () => {
      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const checkbox = screen.getByLabelText('Auto-activate new session');
      expect(checkbox).toBeChecked();

      await userEvent.click(checkbox);
      expect(checkbox).not.toBeChecked();

      await userEvent.click(checkbox);
      expect(checkbox).toBeChecked();
    });

    it('sets autoActivate false when starting session with unchecked box', async () => {
      const { mockSetAutoActivateNextSession } = setupStore();

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      // Uncheck the box
      const checkbox = screen.getByLabelText('Auto-activate new session');
      await userEvent.click(checkbox);

      // Submit form
      await userEvent.click(screen.getByRole('button', { name: 'Start Session' }));

      expect(mockSetAutoActivateNextSession).toHaveBeenCalledWith(false);
    });
  });

  describe('Session Deletion', () => {
    it('renders Close button for each running session', () => {
      setupStore({
        sessions: {
          running: {
            'session-1': createRunningSession({ session_id: 'session-1' }),
            'session-2': createRunningSession({ session_id: 'session-2' }),
          },
          saved: [],
          activeSessionId: null,
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      const closeButtons = screen.getAllByRole('button', { name: 'Close' });
      // 2 sessions = 2 close buttons (the toggle is now "New")
      expect(closeButtons).toHaveLength(2);
    });

    it('calls send with close_session when Close button clicked', async () => {
      const { mockSend } = setupStore({
        sessions: {
          running: {
            'session-1': createRunningSession({ session_id: 'session-1' }),
          },
          saved: [],
          activeSessionId: null,
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      const closeBtn = screen.getByRole('button', { name: 'Close' });
      await userEvent.click(closeBtn);

      expect(mockSend).toHaveBeenCalledWith({
        type: 'close_session',
        session_id: 'session-1',
      });
    });

    it('Close button has danger styling', () => {
      setupStore({
        sessions: {
          running: {
            'session-1': createRunningSession({ session_id: 'session-1' }),
          },
          saved: [],
          activeSessionId: null,
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      const closeBtn = screen.getByRole('button', { name: 'Close' });
      expect(closeBtn).toHaveClass('ghost-button--danger');
    });
  });

  describe('Saved Sessions Section', () => {
    it('renders empty state when no saved sessions', () => {
      render(<Sidebar />);
      expect(screen.getByText('No saved sessions.')).toBeInTheDocument();
    });

    it('renders saved sessions list', () => {
      setupStore({
        sessions: {
          running: {},
          saved: [
            createSavedSession({ id: 'saved-1', cwd: '/path/to/saved1' }),
            createSavedSession({ id: 'saved-2', cwd: '/path/to/saved2' }),
          ],
          activeSessionId: null,
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      expect(screen.getByText('saved-1')).toBeInTheDocument();
      expect(screen.getByText('saved-2')).toBeInTheDocument();
      expect(screen.getByText('/path/to/saved1')).toBeInTheDocument();
      expect(screen.getByText('/path/to/saved2')).toBeInTheDocument();
    });

    it('renders Open button for each saved session', () => {
      setupStore({
        sessions: {
          running: {},
          saved: [
            createSavedSession({ id: 'saved-1' }),
            createSavedSession({ id: 'saved-2' }),
          ],
          activeSessionId: null,
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      const openButtons = screen.getAllByRole('button', { name: 'Open' });
      expect(openButtons).toHaveLength(2);
    });

    it('calls send with start_session using session_file when Open clicked', async () => {
      const { mockSend } = setupStore({
        sessions: {
          running: {},
          saved: [createSavedSession({ path: '/home/.lemon/my-session.jsonl' })],
          activeSessionId: null,
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      const openBtn = screen.getByRole('button', { name: 'Open' });
      await userEvent.click(openBtn);

      expect(mockSend).toHaveBeenCalledWith({
        type: 'start_session',
        session_file: '/home/.lemon/my-session.jsonl',
      });
    });

    it('refreshes saved sessions list when Refresh clicked', async () => {
      const { mockSend } = setupStore();

      render(<Sidebar />);

      const savedSection = screen.getByText('Saved Sessions').closest('.sidebar-section');
      const refreshBtn = within(savedSection!).getByRole('button', { name: 'Refresh' });
      await userEvent.click(refreshBtn);

      expect(mockSend).toHaveBeenCalledWith({ type: 'list_sessions' });
    });
  });

  describe('Models Section', () => {
    it('renders empty state when no models loaded', () => {
      render(<Sidebar />);
      expect(screen.getByText('No models loaded.')).toBeInTheDocument();
    });

    it('renders providers and their models', () => {
      setupStore({ models: createProviders() });

      render(<Sidebar />);

      expect(screen.getByText('anthropic')).toBeInTheDocument();
      expect(screen.getByText('openai')).toBeInTheDocument();

      // Check model tags
      expect(screen.getByText('claude-sonnet-4-20250514')).toBeInTheDocument();
      expect(screen.getByText('claude-opus-4-20250514')).toBeInTheDocument();
      expect(screen.getByText('gpt-4')).toBeInTheDocument();
      expect(screen.getByText('gpt-4-turbo')).toBeInTheDocument();
    });

    it('calls send with list_models when Refresh clicked', async () => {
      const { mockSend } = setupStore();

      render(<Sidebar />);

      const modelsSection = screen.getByText('Models').closest('.sidebar-section');
      const refreshBtn = within(modelsSection!).getByRole('button', { name: 'Refresh' });
      await userEvent.click(refreshBtn);

      expect(mockSend).toHaveBeenCalledWith({ type: 'list_models' });
    });

    it('displays models as tags within provider', () => {
      setupStore({ models: createProviders() });

      render(<Sidebar />);

      const modelTags = document.querySelectorAll('.tag');
      expect(modelTags.length).toBeGreaterThanOrEqual(4); // At least 4 models
    });
  });

  describe('Config Management (Settings)', () => {
    it('renders claude_skip_permissions checkbox with correct state', () => {
      setupStore({
        config: {
          claude_skip_permissions: true,
          codex_auto_approve: false,
        },
      });

      render(<Sidebar />);

      const checkbox = screen.getByLabelText('Claude: Skip Permissions');
      expect(checkbox).toBeChecked();
    });

    it('renders codex_auto_approve checkbox with correct state', () => {
      setupStore({
        config: {
          claude_skip_permissions: false,
          codex_auto_approve: true,
        },
      });

      render(<Sidebar />);

      const checkbox = screen.getByLabelText('Codex: Auto Approve');
      expect(checkbox).toBeChecked();
    });

    it('calls setConfig when claude_skip_permissions toggled', async () => {
      const { mockSetConfig } = setupStore({
        config: {
          claude_skip_permissions: true,
          codex_auto_approve: false,
        },
      });

      render(<Sidebar />);

      const checkbox = screen.getByLabelText('Claude: Skip Permissions');
      await userEvent.click(checkbox);

      expect(mockSetConfig).toHaveBeenCalledWith('claude_skip_permissions', false);
    });

    it('calls setConfig when codex_auto_approve toggled', async () => {
      const { mockSetConfig } = setupStore({
        config: {
          claude_skip_permissions: false,
          codex_auto_approve: false,
        },
      });

      render(<Sidebar />);

      const checkbox = screen.getByLabelText('Codex: Auto Approve');
      await userEvent.click(checkbox);

      expect(mockSetConfig).toHaveBeenCalledWith('codex_auto_approve', true);
    });

    it('calls send with get_config when Settings Refresh clicked', async () => {
      const { mockSend } = setupStore();

      render(<Sidebar />);

      const settingsSection = screen.getByText('Settings').closest('.sidebar-section');
      const refreshBtn = within(settingsSection!).getByRole('button', { name: 'Refresh' });
      await userEvent.click(refreshBtn);

      expect(mockSend).toHaveBeenCalledWith({ type: 'get_config' });
    });
  });

  describe('Editor Section', () => {
    it('shows default message when no editor text', () => {
      setupStore({
        ui: {
          requestsQueue: [],
          status: {},
          widgets: {},
          workingMessage: null,
          title: null,
          editorText: '',
        },
      });

      render(<Sidebar />);

      expect(screen.getByText('No editor text set.')).toBeInTheDocument();
    });

    it('shows editor text when set', () => {
      setupStore({
        ui: {
          requestsQueue: [],
          status: {},
          widgets: {},
          workingMessage: null,
          title: null,
          editorText: 'console.log("Hello World");',
        },
      });

      render(<Sidebar />);

      expect(screen.getByText('console.log("Hello World");')).toBeInTheDocument();
    });
  });

  describe('Debug Section', () => {
    it('toggles debug panel visibility', async () => {
      render(<Sidebar />);

      // Initially hidden
      expect(screen.getByText('Toggle to inspect raw RPC traffic.')).toBeInTheDocument();

      // Click "Show"
      const debugSection = screen.getByText('Debug').closest('.sidebar-section');
      const showBtn = within(debugSection!).getByRole('button', { name: 'Show' });
      await userEvent.click(showBtn);

      // Now visible with empty message
      expect(screen.getByText('No debug events yet.')).toBeInTheDocument();

      // Button text changes to "Hide"
      expect(within(debugSection!).getByRole('button', { name: 'Hide' })).toBeInTheDocument();
    });

    it('displays debug log entries when shown', async () => {
      setupStore({
        debugLog: [
          { type: 'pong', server_time: 12345 },
          { type: 'error', message: 'test error', server_time: 12346 },
        ],
      });

      render(<Sidebar />);

      const debugSection = screen.getByText('Debug').closest('.sidebar-section');
      await userEvent.click(within(debugSection!).getByRole('button', { name: 'Show' }));

      // Check if debug entries are rendered as JSON
      expect(screen.getByText(/"type": "pong"/)).toBeInTheDocument();
      expect(screen.getByText(/"message": "test error"/)).toBeInTheDocument();
    });

    it('renders Quit RPC button', () => {
      render(<Sidebar />);

      expect(screen.getByRole('button', { name: 'Quit RPC' })).toBeInTheDocument();
    });

    it('calls send with quit when Quit RPC clicked', async () => {
      const { mockSend } = setupStore();

      render(<Sidebar />);

      const quitBtn = screen.getByRole('button', { name: 'Quit RPC' });
      await userEvent.click(quitBtn);

      expect(mockSend).toHaveBeenCalledWith({ type: 'quit' });
    });

    it('Quit RPC button has danger styling', () => {
      render(<Sidebar />);

      const quitBtn = screen.getByRole('button', { name: 'Quit RPC' });
      expect(quitBtn).toHaveClass('ghost-button--danger');
    });
  });

  describe('Form Field Updates', () => {
    it('updates CWD field value when typing', async () => {
      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const cwdInput = screen.getByLabelText('CWD') as HTMLInputElement;
      await userEvent.type(cwdInput, '/new/path');

      expect(cwdInput.value).toContain('/new/path');
    });

    it('updates system prompt value when typing', async () => {
      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const textarea = screen.getByLabelText('System Prompt') as HTMLTextAreaElement;
      await userEvent.type(textarea, 'You are a helpful assistant');

      expect(textarea.value).toBe('You are a helpful assistant');
    });

    it('updates session file value when typing', async () => {
      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const input = screen.getByLabelText('Session File') as HTMLInputElement;
      await userEvent.type(input, '/path/to/session.jsonl');

      expect(input.value).toBe('/path/to/session.jsonl');
    });

    it('updates parent session when selected', async () => {
      setupStore({
        sessions: {
          running: {
            'parent-session': createRunningSession({ session_id: 'parent-session' }),
          },
          saved: [],
          activeSessionId: null,
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const select = screen.getByLabelText('Parent Session') as HTMLSelectElement;
      await userEvent.selectOptions(select, 'parent-session');

      expect(select.value).toBe('parent-session');
    });
  });

  describe('Form Defaults from Active Session', () => {
    it('pre-fills CWD from active running session', async () => {
      setupStore({
        sessions: {
          running: {
            'session-1': createRunningSession({ session_id: 'session-1', cwd: '/active/project' }),
          },
          saved: [],
          activeSessionId: 'session-1',
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const cwdInput = screen.getByLabelText('CWD') as HTMLInputElement;
      expect(cwdInput.value).toBe('/active/project');
    });

    it('pre-fills provider from active session stats', async () => {
      setupStore({
        sessions: {
          running: {
            'session-1': createRunningSession({ session_id: 'session-1' }),
          },
          saved: [],
          activeSessionId: 'session-1',
          primarySessionId: null,
        },
        statsBySession: {
          'session-1': createSessionStats({
            model: { provider: 'openai', id: 'gpt-4' },
          }),
        },
        models: createProviders(),
      });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const providerSelect = screen.getByLabelText('Provider') as HTMLSelectElement;
      expect(providerSelect.value).toBe('openai');
    });

    it('backfills provider and model when models load after opening form', async () => {
      setupStore({
        sessions: {
          running: {
            'session-1': createRunningSession({ session_id: 'session-1' }),
          },
          saved: [],
          activeSessionId: 'session-1',
          primarySessionId: null,
        },
        statsBySession: {
          'session-1': createSessionStats({
            model: { provider: 'openai', id: 'gpt-4' },
          }),
        },
        models: [],
      });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));
      expect(screen.getByLabelText('Model').tagName).toBe('INPUT');

      act(() => {
        useLemonStore.setState({ models: createProviders() });
      });

      const providerSelect = (await screen.findByLabelText('Provider')) as HTMLSelectElement;
      const modelSelect = screen.getByLabelText('Model') as HTMLSelectElement;

      await waitFor(() => {
        expect(providerSelect.value).toBe('openai');
        expect(modelSelect.value).toBe('gpt-4');
      });
    });

    it('falls back to first running session cwd when no active session', async () => {
      setupStore({
        sessions: {
          running: {
            'session-1': createRunningSession({ session_id: 'session-1', cwd: '/fallback/project' }),
          },
          saved: [],
          activeSessionId: null,
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const cwdInput = screen.getByLabelText('CWD') as HTMLInputElement;
      expect(cwdInput.value).toBe('/fallback/project');
    });

    it('falls back to first saved session cwd when no running sessions', async () => {
      setupStore({
        sessions: {
          running: {},
          saved: [createSavedSession({ cwd: '/saved/fallback' })],
          activeSessionId: null,
          primarySessionId: null,
        },
      });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const cwdInput = screen.getByLabelText('CWD') as HTMLInputElement;
      expect(cwdInput.value).toBe('/saved/fallback');
    });
  });

  describe('Model Spec Submission', () => {
    it('builds correct model spec from provider and model dropdowns', async () => {
      const { mockSend } = setupStore({ models: createProviders() });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      // Select specific provider and model
      const providerSelect = screen.getByLabelText('Provider');
      await userEvent.selectOptions(providerSelect, 'openai');

      const modelSelect = screen.getByLabelText('Model');
      await userEvent.selectOptions(modelSelect, 'gpt-4-turbo');

      await userEvent.click(screen.getByRole('button', { name: 'Start Session' }));

      expect(mockSend).toHaveBeenCalledWith(
        expect.objectContaining({
          model: 'openai:gpt-4-turbo',
        })
      );
    });

    it('uses modelSpec from text input when no providers', async () => {
      const { mockSend } = setupStore({ models: [] });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      const modelInput = screen.getByLabelText('Model');
      await userEvent.type(modelInput, 'custom:my-model');

      await userEvent.click(screen.getByRole('button', { name: 'Start Session' }));

      expect(mockSend).toHaveBeenCalledWith(
        expect.objectContaining({
          model: 'custom:my-model',
        })
      );
    });

    it('sends undefined model when empty', async () => {
      const { mockSend } = setupStore({ models: [] });

      render(<Sidebar />);

      await userEvent.click(screen.getByRole('button', { name: 'New' }));

      // Don't fill in model
      await userEvent.click(screen.getByRole('button', { name: 'Start Session' }));

      expect(mockSend).toHaveBeenCalledWith(
        expect.objectContaining({
          model: undefined,
        })
      );
    });
  });

  describe('Section Structure', () => {
    it('renders all expected sections', () => {
      render(<Sidebar />);

      expect(screen.getByText('Sessions')).toBeInTheDocument();
      expect(screen.getByText('Saved Sessions')).toBeInTheDocument();
      expect(screen.getByText('Models')).toBeInTheDocument();
      expect(screen.getByText('Editor')).toBeInTheDocument();
      expect(screen.getByText('Settings')).toBeInTheDocument();
      expect(screen.getByText('Debug')).toBeInTheDocument();
    });

    it('uses aside element for sidebar container', () => {
      render(<Sidebar />);

      const sidebar = document.querySelector('aside.sidebar');
      expect(sidebar).toBeInTheDocument();
    });

    it('each section has sidebar-section class', () => {
      render(<Sidebar />);

      const sections = document.querySelectorAll('.sidebar-section');
      expect(sections.length).toBe(6); // Sessions, Saved Sessions, Models, Editor, Settings, Debug
    });
  });
});
