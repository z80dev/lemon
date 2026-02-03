import { cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Composer } from './Composer';
import { useLemonStore } from '../store/useLemonStore';

const initialState = useLemonStore.getState();

beforeEach(() => {
  useLemonStore.setState(initialState, true);
});

afterEach(() => {
  useLemonStore.setState(initialState, true);
  cleanup();
  vi.clearAllMocks();
});

/**
 * Helper to set up a connected session state
 */
function setupConnectedSession(sessionId = 'test-session-1') {
  const mockSendCommand = vi.fn();
  useLemonStore.setState({
    sessions: {
      ...initialState.sessions,
      activeSessionId: sessionId,
    },
    connection: {
      state: 'connected',
      lastError: null,
    },
    sendCommand: mockSendCommand,
  });
  return mockSendCommand;
}

/**
 * Helper to set up a disconnected state
 */
function setupDisconnectedState() {
  useLemonStore.setState({
    sessions: {
      ...initialState.sessions,
      activeSessionId: null,
    },
    connection: {
      state: 'disconnected',
      lastError: null,
    },
    sendCommand: undefined,
  });
}

describe('Composer', () => {
  describe('rendering', () => {
    it('renders the composer with title and hint', () => {
      render(<Composer />);

      expect(screen.getByText('Command Deck')).toBeInTheDocument();
      expect(screen.getByText('Compose Prompt')).toBeInTheDocument();
    });

    it('shows placeholder text in textarea', () => {
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      expect(textarea).toBeInTheDocument();
    });

    it('displays session id when active', () => {
      setupConnectedSession('my-session-id');
      render(<Composer />);

      expect(screen.getByText(/session: my-session-id/)).toBeInTheDocument();
    });

    it('displays session: none when no active session', () => {
      setupDisconnectedState();
      render(<Composer />);

      expect(screen.getByText(/session: none/)).toBeInTheDocument();
    });

    it('displays connection state', () => {
      setupConnectedSession();
      render(<Composer />);

      expect(screen.getByText('connected')).toBeInTheDocument();
    });

    it('displays character count', async () => {
      const user = userEvent.setup();
      setupConnectedSession();
      render(<Composer />);

      expect(screen.getByText('chars: 0')).toBeInTheDocument();

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, 'Hello world');

      expect(screen.getByText('chars: 11')).toBeInTheDocument();
    });

    it('displays Ready when can send', () => {
      setupConnectedSession();
      render(<Composer />);

      expect(screen.getByText('Ready')).toBeInTheDocument();
    });

    it('displays Waiting when cannot send', () => {
      setupDisconnectedState();
      render(<Composer />);

      expect(screen.getByText('Waiting')).toBeInTheDocument();
    });

    it('shows hint for session activation when no active session', () => {
      setupDisconnectedState();
      render(<Composer />);

      expect(
        screen.getByText('Start or activate a session to send prompts.')
      ).toBeInTheDocument();
    });

    it('shows keyboard hint when session is active', () => {
      setupConnectedSession();
      render(<Composer />);

      expect(
        screen.getByText('Enter to send. Shift+Enter for newline.')
      ).toBeInTheDocument();
    });

    it('shows history navigation hint', () => {
      render(<Composer />);

      expect(screen.getByText(/Alt\+↑\/↓ for history/)).toBeInTheDocument();
    });
  });

  describe('text input handling', () => {
    it('updates text state on input', async () => {
      const user = userEvent.setup();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, 'Test input');

      expect(textarea).toHaveValue('Test input');
    });

    it('handles multiline text input', async () => {
      const user = userEvent.setup();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, 'Line 1\nLine 2\nLine 3');

      expect(textarea).toHaveValue('Line 1\nLine 2\nLine 3');
    });

    it('handles very long text input', async () => {
      const user = userEvent.setup();
      render(<Composer />);

      const longText = 'a'.repeat(5000);
      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.click(textarea);
      await user.paste(longText);

      expect(textarea).toHaveValue(longText);
      expect(screen.getByText('chars: 5000')).toBeInTheDocument();
    });

    it('handles special characters in input', async () => {
      const user = userEvent.setup();
      render(<Composer />);

      // Use paste instead of type to avoid userEvent parsing curly braces as special chars
      const specialText = 'const x = () => { return <div>Hello</div>; };';
      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.click(textarea);
      await user.paste(specialText);

      expect(textarea).toHaveValue(specialText);
    });

    it('clears textarea after successful send', async () => {
      const user = userEvent.setup();
      setupConnectedSession();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, 'Hello world');
      await user.keyboard('{Enter}');

      expect(textarea).toHaveValue('');
    });
  });

  describe('send behavior', () => {
    it('sends prompt on Enter key', async () => {
      const user = userEvent.setup();
      const mockSendCommand = setupConnectedSession();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, 'Test prompt');
      await user.keyboard('{Enter}');

      expect(mockSendCommand).toHaveBeenCalledWith({
        type: 'prompt',
        text: 'Test prompt',
        session_id: 'test-session-1',
      });
    });

    it('sends prompt on Send button click', async () => {
      const user = userEvent.setup();
      const mockSendCommand = setupConnectedSession();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, 'Test prompt');

      const sendButton = screen.getByRole('button', { name: 'Send' });
      await user.click(sendButton);

      expect(mockSendCommand).toHaveBeenCalledWith({
        type: 'prompt',
        text: 'Test prompt',
        session_id: 'test-session-1',
      });
    });

    it('does not send empty text', async () => {
      const user = userEvent.setup();
      const mockSendCommand = setupConnectedSession();
      render(<Composer />);

      const sendButton = screen.getByRole('button', { name: 'Send' });
      await user.click(sendButton);

      expect(mockSendCommand).not.toHaveBeenCalled();
    });

    it('does not send whitespace-only text', async () => {
      const user = userEvent.setup();
      const mockSendCommand = setupConnectedSession();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, '   \n\t  ');
      await user.keyboard('{Enter}');

      expect(mockSendCommand).not.toHaveBeenCalled();
    });

    it('trims text before sending', async () => {
      const user = userEvent.setup();
      const mockSendCommand = setupConnectedSession();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, '  Test prompt  ');
      await user.keyboard('{Enter}');

      expect(mockSendCommand).toHaveBeenCalledWith(
        expect.objectContaining({
          text: 'Test prompt',
        })
      );
    });
  });

  describe('send validation', () => {
    it('requires active session to send', async () => {
      const user = userEvent.setup();
      const mockSendCommand = vi.fn();
      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: null,
        },
        connection: {
          state: 'connected',
          lastError: null,
        },
        sendCommand: mockSendCommand,
      });
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, 'Test prompt');
      await user.keyboard('{Enter}');

      expect(mockSendCommand).not.toHaveBeenCalled();
    });

    it('requires connection to send', async () => {
      const user = userEvent.setup();
      const mockSendCommand = vi.fn();
      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: 'test-session',
        },
        connection: {
          state: 'disconnected',
          lastError: null,
        },
        sendCommand: mockSendCommand,
      });
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, 'Test prompt');
      await user.keyboard('{Enter}');

      // Should not call sendCommand when disconnected
      expect(mockSendCommand).not.toHaveBeenCalled();
    });

    it('enqueues notification when sendCommand is not ready', async () => {
      const user = userEvent.setup();
      const mockEnqueue = vi.fn();
      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: 'test-session',
        },
        connection: {
          state: 'connected',
          lastError: null,
        },
        sendCommand: undefined,
        enqueueNotification: mockEnqueue,
      });
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, 'Test prompt');
      await user.keyboard('{Enter}');

      expect(mockEnqueue).toHaveBeenCalledWith(
        expect.objectContaining({
          message: 'WebSocket not ready yet. Please wait a moment and try again.',
          level: 'error',
        })
      );
    });

    it('enqueues notification when disconnected', async () => {
      const user = userEvent.setup();
      const mockEnqueue = vi.fn();
      const mockSendCommand = vi.fn();
      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: 'test-session',
        },
        connection: {
          state: 'disconnected',
          lastError: null,
        },
        sendCommand: mockSendCommand,
        enqueueNotification: mockEnqueue,
      });
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, 'Test prompt');
      await user.keyboard('{Enter}');

      expect(mockEnqueue).toHaveBeenCalledWith(
        expect.objectContaining({
          message: 'Cannot send while disconnected. Check the connection and try again.',
          level: 'error',
        })
      );
    });
  });

  describe('Shift+Enter behavior', () => {
    it('inserts newline on Shift+Enter', async () => {
      const user = userEvent.setup();
      setupConnectedSession();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, 'Line 1');
      await user.keyboard('{Shift>}{Enter}{/Shift}');
      await user.type(textarea, 'Line 2');

      expect(textarea).toHaveValue('Line 1\nLine 2');
    });

    it('does not send on Shift+Enter', async () => {
      const user = userEvent.setup();
      const mockSendCommand = setupConnectedSession();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, 'Line 1');
      await user.keyboard('{Shift>}{Enter}{/Shift}');

      expect(mockSendCommand).not.toHaveBeenCalled();
    });
  });

  describe('command history navigation', () => {
    it('navigates to previous command with Alt+ArrowUp', async () => {
      const user = userEvent.setup();
      setupConnectedSession();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );

      // Send first command
      await user.type(textarea, 'first command');
      await user.keyboard('{Enter}');

      // Send second command
      await user.type(textarea, 'second command');
      await user.keyboard('{Enter}');

      // Navigate back
      await user.keyboard('{Alt>}{ArrowUp}{/Alt}');
      expect(textarea).toHaveValue('second command');

      await user.keyboard('{Alt>}{ArrowUp}{/Alt}');
      expect(textarea).toHaveValue('first command');
    });

    it('navigates to next command with Alt+ArrowDown', async () => {
      const user = userEvent.setup();
      setupConnectedSession();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );

      // Send commands
      await user.type(textarea, 'first command');
      await user.keyboard('{Enter}');
      await user.type(textarea, 'second command');
      await user.keyboard('{Enter}');

      // Navigate to oldest
      await user.keyboard('{Alt>}{ArrowUp}{/Alt}');
      await user.keyboard('{Alt>}{ArrowUp}{/Alt}');
      expect(textarea).toHaveValue('first command');

      // Navigate forward
      await user.keyboard('{Alt>}{ArrowDown}{/Alt}');
      expect(textarea).toHaveValue('second command');
    });

    it('keeps text when navigating past most recent command', async () => {
      const user = userEvent.setup();
      setupConnectedSession();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );

      // Send command
      await user.type(textarea, 'test command');
      await user.keyboard('{Enter}');

      // Navigate to command
      await user.keyboard('{Alt>}{ArrowUp}{/Alt}');
      expect(textarea).toHaveValue('test command');

      // Navigate past it - text stays (historyIndex becomes null but text isn't cleared)
      // This allows the user to modify old commands without losing edits
      await user.keyboard('{Alt>}{ArrowDown}{/Alt}');
      expect(textarea).toHaveValue('test command');
    });

    it('does nothing on Alt+ArrowUp with empty history', async () => {
      const user = userEvent.setup();
      setupConnectedSession();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );

      await user.type(textarea, 'current text');
      await user.keyboard('{Alt>}{ArrowUp}{/Alt}');

      // Should remain unchanged when history is empty
      expect(textarea).toHaveValue('current text');
    });

    it('does not navigate beyond oldest command', async () => {
      const user = userEvent.setup();
      setupConnectedSession();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );

      // Send one command
      await user.type(textarea, 'only command');
      await user.keyboard('{Enter}');

      // Try to navigate beyond
      await user.keyboard('{Alt>}{ArrowUp}{/Alt}');
      await user.keyboard('{Alt>}{ArrowUp}{/Alt}');
      await user.keyboard('{Alt>}{ArrowUp}{/Alt}');

      expect(textarea).toHaveValue('only command');
    });

    it('limits history to 50 entries', async () => {
      const user = userEvent.setup();
      setupConnectedSession();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );

      // Send 55 commands
      for (let i = 1; i <= 55; i++) {
        await user.type(textarea, `command ${i}`);
        await user.keyboard('{Enter}');
      }

      // Navigate through history - should only be able to go back 50
      for (let i = 0; i < 55; i++) {
        await user.keyboard('{Alt>}{ArrowUp}{/Alt}');
      }

      // Should be at the 6th command (oldest in limited history)
      expect(textarea).toHaveValue('command 6');
    });
  });

  describe('disabled states', () => {
    it('disables Send button when cannot send', () => {
      setupDisconnectedState();
      render(<Composer />);

      const sendButton = screen.getByRole('button', { name: 'Send' });
      expect(sendButton).toBeDisabled();
    });

    it('enables Send button when can send', () => {
      setupConnectedSession();
      render(<Composer />);

      const sendButton = screen.getByRole('button', { name: 'Send' });
      expect(sendButton).not.toBeDisabled();
    });

    it('disables Abort button when no active session', () => {
      setupDisconnectedState();
      render(<Composer />);

      const abortButton = screen.getByRole('button', { name: 'Abort' });
      expect(abortButton).toBeDisabled();
    });

    it('disables Reset button when no active session', () => {
      setupDisconnectedState();
      render(<Composer />);

      const resetButton = screen.getByRole('button', { name: 'Reset' });
      expect(resetButton).toBeDisabled();
    });

    it('disables Save button when no active session', () => {
      setupDisconnectedState();
      render(<Composer />);

      const saveButton = screen.getByRole('button', { name: 'Save' });
      expect(saveButton).toBeDisabled();
    });

    it('enables action buttons when session is active', () => {
      setupConnectedSession();
      render(<Composer />);

      expect(screen.getByRole('button', { name: 'Abort' })).not.toBeDisabled();
      expect(screen.getByRole('button', { name: 'Reset' })).not.toBeDisabled();
      expect(screen.getByRole('button', { name: 'Save' })).not.toBeDisabled();
    });
  });

  describe('Abort button', () => {
    it('sends abort command on click', async () => {
      const user = userEvent.setup();
      const mockSendCommand = setupConnectedSession('session-abc');
      render(<Composer />);

      const abortButton = screen.getByRole('button', { name: 'Abort' });
      await user.click(abortButton);

      expect(mockSendCommand).toHaveBeenCalledWith({
        type: 'abort',
        session_id: 'session-abc',
      });
    });
  });

  describe('Reset button', () => {
    it('sends reset command on click', async () => {
      const user = userEvent.setup();
      const mockSendCommand = setupConnectedSession('session-xyz');
      render(<Composer />);

      const resetButton = screen.getByRole('button', { name: 'Reset' });
      await user.click(resetButton);

      expect(mockSendCommand).toHaveBeenCalledWith({
        type: 'reset',
        session_id: 'session-xyz',
      });
    });
  });

  describe('Save button', () => {
    it('sends save command on click', async () => {
      const user = userEvent.setup();
      const mockSendCommand = setupConnectedSession('session-123');
      render(<Composer />);

      const saveButton = screen.getByRole('button', { name: 'Save' });
      await user.click(saveButton);

      expect(mockSendCommand).toHaveBeenCalledWith({
        type: 'save',
        session_id: 'session-123',
      });
    });
  });

  describe('focus management', () => {
    it('focuses textarea after sending', async () => {
      const user = userEvent.setup();
      setupConnectedSession();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, 'Test prompt');
      await user.keyboard('{Enter}');

      expect(textarea).toHaveFocus();
    });

    it('focuses textarea after clicking Send button', async () => {
      const user = userEvent.setup();
      setupConnectedSession();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, 'Test prompt');

      const sendButton = screen.getByRole('button', { name: 'Send' });
      await user.click(sendButton);

      expect(textarea).toHaveFocus();
    });
  });

  describe('connection state display', () => {
    it('displays connecting state', () => {
      useLemonStore.setState({
        connection: {
          state: 'connecting',
          lastError: null,
        },
      });
      render(<Composer />);

      expect(screen.getByText('connecting')).toBeInTheDocument();
    });

    it('displays disconnected state', () => {
      useLemonStore.setState({
        connection: {
          state: 'disconnected',
          lastError: null,
        },
      });
      render(<Composer />);

      expect(screen.getByText('disconnected')).toBeInTheDocument();
    });

    it('displays error state', () => {
      useLemonStore.setState({
        connection: {
          state: 'error',
          lastError: 'Connection failed',
        },
      });
      render(<Composer />);

      expect(screen.getByText('error')).toBeInTheDocument();
    });

    it('applies correct CSS class for connection state', () => {
      useLemonStore.setState({
        connection: {
          state: 'connected',
          lastError: null,
        },
      });
      render(<Composer />);

      const chip = screen.getByText('connected');
      expect(chip).toHaveClass('composer__chip--connected');
    });
  });

  describe('character count', () => {
    it('counts trimmed characters', async () => {
      const user = userEvent.setup();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, '  hello  ');

      // Trim removes leading/trailing whitespace, so 5 chars
      expect(screen.getByText('chars: 5')).toBeInTheDocument();
    });

    it('counts zero for whitespace-only input', async () => {
      const user = userEvent.setup();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, '   ');

      expect(screen.getByText('chars: 0')).toBeInTheDocument();
    });

    it('counts newlines in trimmed text', async () => {
      const user = userEvent.setup();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, 'a\nb\nc');

      // 'a\nb\nc' is 5 chars (3 letters + 2 newlines)
      expect(screen.getByText('chars: 5')).toBeInTheDocument();
    });
  });

  describe('history stores trimmed text', () => {
    it('stores trimmed text in history', async () => {
      const user = userEvent.setup();
      setupConnectedSession();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );

      await user.type(textarea, '  command with spaces  ');
      await user.keyboard('{Enter}');

      await user.keyboard('{Alt>}{ArrowUp}{/Alt}');
      expect(textarea).toHaveValue('command with spaces');
    });
  });

  describe('prevents default Enter behavior', () => {
    it('prevents form submission on Enter', async () => {
      const user = userEvent.setup();
      setupConnectedSession();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, 'test');
      await user.keyboard('{Enter}');

      // Should not have newline in cleared textarea
      expect(textarea).toHaveValue('');
    });
  });

  describe('edge cases', () => {
    it('handles rapid send attempts gracefully', async () => {
      const user = userEvent.setup();
      const mockSendCommand = setupConnectedSession();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, 'test');
      await user.keyboard('{Enter}');
      await user.keyboard('{Enter}');
      await user.keyboard('{Enter}');

      // Should only send once (subsequent enters have empty text)
      expect(mockSendCommand).toHaveBeenCalledTimes(1);
    });

    it('handles session ID with special characters', async () => {
      const user = userEvent.setup();
      const sessionId = 'session-with-special_chars.123';
      const mockSendCommand = setupConnectedSession(sessionId);
      render(<Composer />);

      expect(screen.getByText(`session: ${sessionId}`)).toBeInTheDocument();

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      await user.type(textarea, 'test');
      await user.keyboard('{Enter}');

      expect(mockSendCommand).toHaveBeenCalledWith(
        expect.objectContaining({
          session_id: sessionId,
        })
      );
    });

    it('handles unicode text input', async () => {
      const user = userEvent.setup();
      const mockSendCommand = setupConnectedSession();
      render(<Composer />);

      const textarea = screen.getByPlaceholderText(
        'Draft a plan, paste logs, or ask for a change...'
      );
      const unicodeText = 'Hello \u4e16\u754c \ud83d\udc4b';
      await user.type(textarea, unicodeText);
      await user.keyboard('{Enter}');

      expect(mockSendCommand).toHaveBeenCalledWith(
        expect.objectContaining({
          text: unicodeText,
        })
      );
    });

    it('uses store send function for action buttons', async () => {
      const user = userEvent.setup();
      const mockSend = vi.fn();
      useLemonStore.setState({
        sessions: {
          ...initialState.sessions,
          activeSessionId: 'test-session',
        },
        send: mockSend,
      });
      render(<Composer />);

      const abortButton = screen.getByRole('button', { name: 'Abort' });
      await user.click(abortButton);

      expect(mockSend).toHaveBeenCalledWith({
        type: 'abort',
        session_id: 'test-session',
      });
    });
  });
});
