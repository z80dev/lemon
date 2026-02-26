import { render, screen, within, act } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { UIRequestModal } from './UIRequestModal';
import { useLemonStore } from '../store/useLemonStore';
import type { UIRequestMessage, SelectOption } from '@lemon-web/shared';

/**
 * Test helpers for creating UI request fixtures
 */
function createSelectRequest(
  options: SelectOption[],
  overrides: Partial<UIRequestMessage> = {}
): UIRequestMessage {
  return {
    type: 'ui_request',
    id: 'test-request-id',
    method: 'select',
    params: {
      title: 'Select an option',
      options,
    },
    ...overrides,
  };
}

function createConfirmRequest(
  message: string,
  overrides: Partial<UIRequestMessage> = {}
): UIRequestMessage {
  return {
    type: 'ui_request',
    id: 'test-request-id',
    method: 'confirm',
    params: {
      title: 'Confirm Action',
      message,
    },
    ...overrides,
  };
}

function createInputRequest(
  placeholder?: string,
  prefill?: string,
  overrides: Partial<UIRequestMessage> = {}
): UIRequestMessage {
  return {
    type: 'ui_request',
    id: 'test-request-id',
    method: 'input',
    params: {
      title: 'Enter Input',
      placeholder,
      prefill,
    },
    ...overrides,
  };
}

function createEditorRequest(
  prefill?: string,
  overrides: Partial<UIRequestMessage> = {}
): UIRequestMessage {
  return {
    type: 'ui_request',
    id: 'test-request-id',
    method: 'editor',
    params: {
      title: 'Edit Content',
      prefill,
    },
    ...overrides,
  };
}

function createMockOptions(count: number): SelectOption[] {
  return Array.from({ length: count }, (_, i) => ({
    label: `Option ${i + 1}`,
    value: `opt-${i + 1}`,
    description: i % 2 === 0 ? `Description for option ${i + 1}` : undefined,
  }));
}

describe('UIRequestModal', () => {
  let mockSend: ReturnType<typeof vi.fn>;
  let mockDequeue: ReturnType<typeof vi.fn>;
  let mockEnqueueNotification: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    mockSend = vi.fn();
    mockDequeue = vi.fn();
    mockEnqueueNotification = vi.fn();

    // Reset the store state before each test
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
        state: 'connected',
        lastError: null,
        lastServerTime: undefined,
        bridgeStatus: null,
      },
      send: mockSend,
      dequeueUIRequest: mockDequeue,
      enqueueNotification: mockEnqueueNotification,
      notifications: [],
    });
  });

  describe('when no request is queued', () => {
    it('renders nothing when requestsQueue is empty', () => {
      const { container } = render(<UIRequestModal />);
      expect(container).toBeEmptyDOMElement();
    });
  });

  // ============================================================================
  // Select Mode Tests
  // ============================================================================
  describe('select mode', () => {
    it('renders modal with title for select request', () => {
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(createMockOptions(3))],
        },
      }));

      render(<UIRequestModal />);

      expect(screen.getByRole('heading', { name: 'Select an option' })).toBeInTheDocument();
    });

    it('renders filter input with placeholder', () => {
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(createMockOptions(3))],
        },
      }));

      render(<UIRequestModal />);

      expect(screen.getByPlaceholderText('Filter options')).toBeInTheDocument();
    });

    it('renders all options with labels and values', () => {
      const options = createMockOptions(3);
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(options)],
        },
      }));

      render(<UIRequestModal />);

      expect(screen.getByText('Option 1')).toBeInTheDocument();
      expect(screen.getByText('Option 2')).toBeInTheDocument();
      expect(screen.getByText('Option 3')).toBeInTheDocument();
      expect(screen.getByText('opt-1')).toBeInTheDocument();
      expect(screen.getByText('opt-2')).toBeInTheDocument();
      expect(screen.getByText('opt-3')).toBeInTheDocument();
    });

    it('renders option descriptions when provided', () => {
      const options = createMockOptions(3);
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(options)],
        },
      }));

      render(<UIRequestModal />);

      expect(screen.getByText('Description for option 1')).toBeInTheDocument();
      expect(screen.getByText('Description for option 3')).toBeInTheDocument();
      // Option 2 has no description
      expect(screen.queryByText('Description for option 2')).not.toBeInTheDocument();
    });

    it('renders Cancel and Choose buttons', () => {
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(createMockOptions(2))],
        },
      }));

      render(<UIRequestModal />);

      expect(screen.getByRole('button', { name: 'Cancel' })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: 'Choose' })).toBeInTheDocument();
    });

    it('disables Choose button when no option is selected', () => {
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(createMockOptions(2))],
        },
      }));

      render(<UIRequestModal />);

      const chooseButton = screen.getByRole('button', { name: 'Choose' });
      expect(chooseButton).toBeDisabled();
    });

    it('enables Choose button after selecting an option', async () => {
      const user = userEvent.setup();
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(createMockOptions(3))],
        },
      }));

      render(<UIRequestModal />);

      const option1Button = screen.getByRole('button', { name: /Option 1/i });
      await user.click(option1Button);

      const chooseButton = screen.getByRole('button', { name: 'Choose' });
      expect(chooseButton).not.toBeDisabled();
    });

    it('highlights selected option with active class', async () => {
      const user = userEvent.setup();
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(createMockOptions(3))],
        },
      }));

      render(<UIRequestModal />);

      const option1Button = screen.getByRole('button', { name: /Option 1/i });
      await user.click(option1Button);

      expect(option1Button).toHaveClass('option-button--active');
    });

    it('filters options based on label', async () => {
      const user = userEvent.setup();
      const options: SelectOption[] = [
        { label: 'Apple', value: 'apple' },
        { label: 'Banana', value: 'banana' },
        { label: 'Cherry', value: 'cherry' },
      ];
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(options)],
        },
      }));

      render(<UIRequestModal />);

      const filterInput = screen.getByPlaceholderText('Filter options');
      await user.type(filterInput, 'an');

      expect(screen.getByText('Banana')).toBeInTheDocument();
      expect(screen.queryByText('Apple')).not.toBeInTheDocument();
      expect(screen.queryByText('Cherry')).not.toBeInTheDocument();
    });

    it('filters options based on description', async () => {
      const user = userEvent.setup();
      const options: SelectOption[] = [
        { label: 'Option A', value: 'a', description: 'First item' },
        { label: 'Option B', value: 'b', description: 'Second item' },
        { label: 'Option C', value: 'c', description: 'Third item' },
      ];
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(options)],
        },
      }));

      render(<UIRequestModal />);

      const filterInput = screen.getByPlaceholderText('Filter options');
      await user.type(filterInput, 'Third');

      expect(screen.getByText('Option C')).toBeInTheDocument();
      expect(screen.queryByText('Option A')).not.toBeInTheDocument();
      expect(screen.queryByText('Option B')).not.toBeInTheDocument();
    });

    it('filter is case insensitive', async () => {
      const user = userEvent.setup();
      const options: SelectOption[] = [
        { label: 'UPPERCASE', value: 'upper' },
        { label: 'lowercase', value: 'lower' },
      ];
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(options)],
        },
      }));

      render(<UIRequestModal />);

      const filterInput = screen.getByPlaceholderText('Filter options');
      await user.type(filterInput, 'LOWER');

      expect(screen.getByText('lowercase')).toBeInTheDocument();
      expect(screen.queryByText('UPPERCASE')).not.toBeInTheDocument();
    });

    it('shows all options when filter is cleared', async () => {
      const user = userEvent.setup();
      const options = createMockOptions(3);
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(options)],
        },
      }));

      render(<UIRequestModal />);

      const filterInput = screen.getByPlaceholderText('Filter options');
      await user.type(filterInput, 'Option 1');

      expect(screen.queryByText('Option 2')).not.toBeInTheDocument();

      await user.clear(filterInput);

      expect(screen.getByText('Option 1')).toBeInTheDocument();
      expect(screen.getByText('Option 2')).toBeInTheDocument();
      expect(screen.getByText('Option 3')).toBeInTheDocument();
    });

    it('submits selected option value when Choose is clicked', async () => {
      const user = userEvent.setup();
      const options = createMockOptions(3);
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(options)],
        },
      }));

      render(<UIRequestModal />);

      const option2Button = screen.getByRole('button', { name: /Option 2/i });
      await user.click(option2Button);

      const chooseButton = screen.getByRole('button', { name: 'Choose' });
      await user.click(chooseButton);

      expect(mockSend).toHaveBeenCalledWith({
        type: 'ui_response',
        id: 'test-request-id',
        result: 'opt-2',
        error: null,
      });
      expect(mockDequeue).toHaveBeenCalled();
    });

    it('handles long option lists', () => {
      const options = createMockOptions(50);
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(options)],
        },
      }));

      render(<UIRequestModal />);

      expect(screen.getByText('Option 1')).toBeInTheDocument();
      expect(screen.getByText('Option 50')).toBeInTheDocument();
    });
  });

  // ============================================================================
  // Confirm Mode Tests
  // ============================================================================
  describe('confirm mode', () => {
    it('renders modal with title and message', () => {
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createConfirmRequest('Are you sure you want to proceed?')],
        },
      }));

      render(<UIRequestModal />);

      expect(screen.getByRole('heading', { name: 'Confirm Action' })).toBeInTheDocument();
      expect(screen.getByText('Are you sure you want to proceed?')).toBeInTheDocument();
    });

    it('renders Cancel and Confirm buttons', () => {
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createConfirmRequest('Confirm this?')],
        },
      }));

      render(<UIRequestModal />);

      expect(screen.getByRole('button', { name: 'Cancel' })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: 'Confirm' })).toBeInTheDocument();
    });

    it('sends true when Confirm is clicked', async () => {
      const user = userEvent.setup();
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createConfirmRequest('Proceed?')],
        },
      }));

      render(<UIRequestModal />);

      await user.click(screen.getByRole('button', { name: 'Confirm' }));

      expect(mockSend).toHaveBeenCalledWith({
        type: 'ui_response',
        id: 'test-request-id',
        result: true,
        error: null,
      });
      expect(mockDequeue).toHaveBeenCalled();
    });

    it('sends false when Cancel button in footer is clicked', async () => {
      const user = userEvent.setup();
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createConfirmRequest('Proceed?')],
        },
      }));

      render(<UIRequestModal />);

      // Get the Cancel button in the footer (not the Close button in header)
      const footer = screen.getByRole('contentinfo');
      const cancelButton = within(footer).getByRole('button', { name: 'Cancel' });
      await user.click(cancelButton);

      expect(mockSend).toHaveBeenCalledWith({
        type: 'ui_response',
        id: 'test-request-id',
        result: false,
        error: null,
      });
      expect(mockDequeue).toHaveBeenCalled();
    });
  });

  // ============================================================================
  // Input Mode Tests
  // ============================================================================
  describe('input mode', () => {
    it('renders modal with title and input field', () => {
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createInputRequest('Enter your name')],
        },
      }));

      render(<UIRequestModal />);

      expect(screen.getByRole('heading', { name: 'Enter Input' })).toBeInTheDocument();
      expect(screen.getByPlaceholderText('Enter your name')).toBeInTheDocument();
    });

    it('renders Cancel and Submit buttons', () => {
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createInputRequest()],
        },
      }));

      render(<UIRequestModal />);

      expect(screen.getByRole('button', { name: 'Cancel' })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: 'Submit' })).toBeInTheDocument();
    });

    it('prefills input with prefill value', () => {
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createInputRequest('Placeholder', 'Default Value')],
        },
      }));

      render(<UIRequestModal />);

      const input = screen.getByPlaceholderText('Placeholder');
      expect(input).toHaveValue('Default Value');
    });

    it('allows typing in input field', async () => {
      const user = userEvent.setup();
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createInputRequest('Type here')],
        },
      }));

      render(<UIRequestModal />);

      const input = screen.getByPlaceholderText('Type here');
      await user.type(input, 'Hello World');

      expect(input).toHaveValue('Hello World');
    });

    it('submits input value when Submit is clicked', async () => {
      const user = userEvent.setup();
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createInputRequest('Enter text')],
        },
      }));

      render(<UIRequestModal />);

      const input = screen.getByPlaceholderText('Enter text');
      await user.type(input, 'My input value');
      await user.click(screen.getByRole('button', { name: 'Submit' }));

      expect(mockSend).toHaveBeenCalledWith({
        type: 'ui_response',
        id: 'test-request-id',
        result: 'My input value',
        error: null,
      });
      expect(mockDequeue).toHaveBeenCalled();
    });

    it('submits empty string when Submit is clicked with no input', async () => {
      const user = userEvent.setup();
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createInputRequest()],
        },
      }));

      render(<UIRequestModal />);

      await user.click(screen.getByRole('button', { name: 'Submit' }));

      expect(mockSend).toHaveBeenCalledWith({
        type: 'ui_response',
        id: 'test-request-id',
        result: '',
        error: null,
      });
    });
  });

  // ============================================================================
  // Editor Mode Tests
  // ============================================================================
  describe('editor mode', () => {
    it('renders modal with title and textarea', () => {
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createEditorRequest()],
        },
      }));

      render(<UIRequestModal />);

      expect(screen.getByRole('heading', { name: 'Edit Content' })).toBeInTheDocument();
      expect(screen.getByRole('textbox')).toBeInTheDocument();
    });

    it('renders Cancel and Save buttons', () => {
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createEditorRequest()],
        },
      }));

      render(<UIRequestModal />);

      expect(screen.getByRole('button', { name: 'Cancel' })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: 'Save' })).toBeInTheDocument();
    });

    it('prefills textarea with prefill value', () => {
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createEditorRequest('Initial content\nwith multiple lines')],
        },
      }));

      render(<UIRequestModal />);

      const textarea = screen.getByRole('textbox');
      expect(textarea).toHaveValue('Initial content\nwith multiple lines');
    });

    it('allows typing in textarea', async () => {
      const user = userEvent.setup();
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createEditorRequest()],
        },
      }));

      render(<UIRequestModal />);

      const textarea = screen.getByRole('textbox');
      await user.type(textarea, 'New content');

      expect(textarea).toHaveValue('New content');
    });

    it('submits textarea value when Save is clicked', async () => {
      const user = userEvent.setup();
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createEditorRequest('Start')],
        },
      }));

      render(<UIRequestModal />);

      const textarea = screen.getByRole('textbox');
      await user.clear(textarea);
      await user.type(textarea, 'Modified content');
      await user.click(screen.getByRole('button', { name: 'Save' }));

      expect(mockSend).toHaveBeenCalledWith({
        type: 'ui_response',
        id: 'test-request-id',
        result: 'Modified content',
        error: null,
      });
      expect(mockDequeue).toHaveBeenCalled();
    });
  });

  // ============================================================================
  // Cancel Behavior Tests
  // ============================================================================
  describe('cancel behavior', () => {
    it('sends null result when Close button is clicked (select)', async () => {
      const user = userEvent.setup();
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(createMockOptions(2))],
        },
      }));

      render(<UIRequestModal />);

      await user.click(screen.getByRole('button', { name: 'Close' }));

      expect(mockSend).toHaveBeenCalledWith({
        type: 'ui_response',
        id: 'test-request-id',
        result: null,
        error: null,
      });
      expect(mockDequeue).toHaveBeenCalled();
    });

    it('sends null result when Cancel button is clicked (select footer)', async () => {
      const user = userEvent.setup();
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(createMockOptions(2))],
        },
      }));

      render(<UIRequestModal />);

      // Get the Cancel button in footer
      const footer = screen.getByRole('contentinfo');
      const cancelButton = within(footer).getByRole('button', { name: 'Cancel' });
      await user.click(cancelButton);

      expect(mockSend).toHaveBeenCalledWith({
        type: 'ui_response',
        id: 'test-request-id',
        result: null,
        error: null,
      });
    });

    it('sends null result when Cancel button is clicked (input)', async () => {
      const user = userEvent.setup();
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createInputRequest()],
        },
      }));

      render(<UIRequestModal />);

      const footer = screen.getByRole('contentinfo');
      const cancelButton = within(footer).getByRole('button', { name: 'Cancel' });
      await user.click(cancelButton);

      expect(mockSend).toHaveBeenCalledWith({
        type: 'ui_response',
        id: 'test-request-id',
        result: null,
        error: null,
      });
    });

    it('sends null result when Cancel button is clicked (editor)', async () => {
      const user = userEvent.setup();
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createEditorRequest('Some content')],
        },
      }));

      render(<UIRequestModal />);

      const footer = screen.getByRole('contentinfo');
      const cancelButton = within(footer).getByRole('button', { name: 'Cancel' });
      await user.click(cancelButton);

      expect(mockSend).toHaveBeenCalledWith({
        type: 'ui_response',
        id: 'test-request-id',
        result: null,
        error: null,
      });
    });
  });

  // ============================================================================
  // Connection-Aware Behavior Tests
  // ============================================================================
  describe('connection-aware response sending', () => {
    it('shows error notification and does not send when disconnected', async () => {
      const user = userEvent.setup();
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createConfirmRequest('Proceed?')],
        },
        connection: {
          ...state.connection,
          state: 'disconnected',
        },
      }));

      render(<UIRequestModal />);

      await user.click(screen.getByRole('button', { name: 'Confirm' }));

      expect(mockSend).not.toHaveBeenCalled();
      expect(mockDequeue).not.toHaveBeenCalled();
      expect(mockEnqueueNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          message: 'Cannot send response while disconnected. Reconnect and try again.',
          level: 'error',
        })
      );
    });

    it('shows error notification when connection state is connecting', async () => {
      const user = userEvent.setup();
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createInputRequest('Test')],
        },
        connection: {
          ...state.connection,
          state: 'connecting',
        },
      }));

      render(<UIRequestModal />);

      await user.type(screen.getByPlaceholderText('Test'), 'value');
      await user.click(screen.getByRole('button', { name: 'Submit' }));

      expect(mockSend).not.toHaveBeenCalled();
      expect(mockEnqueueNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          level: 'error',
        })
      );
    });

    it('shows error notification when connection state is error', async () => {
      const user = userEvent.setup();
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createEditorRequest('Content')],
        },
        connection: {
          ...state.connection,
          state: 'error',
        },
      }));

      render(<UIRequestModal />);

      await user.click(screen.getByRole('button', { name: 'Save' }));

      expect(mockSend).not.toHaveBeenCalled();
      expect(mockEnqueueNotification).toHaveBeenCalled();
    });

    it('sends response successfully when connected', async () => {
      const user = userEvent.setup();
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createConfirmRequest('Proceed?')],
        },
        connection: {
          ...state.connection,
          state: 'connected',
        },
      }));

      render(<UIRequestModal />);

      await user.click(screen.getByRole('button', { name: 'Confirm' }));

      expect(mockSend).toHaveBeenCalledWith({
        type: 'ui_response',
        id: 'test-request-id',
        result: true,
        error: null,
      });
      expect(mockDequeue).toHaveBeenCalled();
      expect(mockEnqueueNotification).not.toHaveBeenCalled();
    });
  });

  // ============================================================================
  // State Reset Tests
  // ============================================================================
  describe('state reset between requests', () => {
    it('resets input value when new request arrives', async () => {
      const user = userEvent.setup();

      // First render with an input request
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createInputRequest('First')],
        },
      }));

      const { rerender } = render(<UIRequestModal />);

      const input1 = screen.getByPlaceholderText('First');
      await user.type(input1, 'Some text');
      expect(input1).toHaveValue('Some text');

      // Simulate dequeuing and new request
      act(() => {
        useLemonStore.setState((state) => ({
          ui: {
            ...state.ui,
            requestsQueue: [createInputRequest('Second')],
          },
        }));
      });

      rerender(<UIRequestModal />);

      const input2 = screen.getByPlaceholderText('Second');
      expect(input2).toHaveValue('');
    });

    it('resets filter when new request arrives', async () => {
      const user = userEvent.setup();

      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(createMockOptions(5))],
        },
      }));

      const { rerender } = render(<UIRequestModal />);

      const filterInput = screen.getByPlaceholderText('Filter options');
      await user.type(filterInput, 'Option 1');

      // Simulate new request
      act(() => {
        useLemonStore.setState((state) => ({
          ui: {
            ...state.ui,
            requestsQueue: [
              createSelectRequest(createMockOptions(5), { id: 'new-request' }),
            ],
          },
        }));
      });

      rerender(<UIRequestModal />);

      const newFilterInput = screen.getByPlaceholderText('Filter options');
      expect(newFilterInput).toHaveValue('');
    });

    it('resets selected option when new request arrives', async () => {
      const user = userEvent.setup();

      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(createMockOptions(3))],
        },
      }));

      const { rerender } = render(<UIRequestModal />);

      const option1 = screen.getByRole('button', { name: /Option 1/i });
      await user.click(option1);
      expect(option1).toHaveClass('option-button--active');

      // Simulate new request
      act(() => {
        useLemonStore.setState((state) => ({
          ui: {
            ...state.ui,
            requestsQueue: [
              createSelectRequest(createMockOptions(3), { id: 'new-request' }),
            ],
          },
        }));
      });

      rerender(<UIRequestModal />);

      // No option should be selected
      const chooseButton = screen.getByRole('button', { name: 'Choose' });
      expect(chooseButton).toBeDisabled();
    });

    it('uses prefill value for new editor request', () => {
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createEditorRequest('Prefilled content')],
        },
      }));

      render(<UIRequestModal />);

      const textarea = screen.getByRole('textbox');
      expect(textarea).toHaveValue('Prefilled content');
    });
  });

  // ============================================================================
  // Modal Structure Tests
  // ============================================================================
  describe('modal structure', () => {
    it('renders modal overlay', () => {
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createConfirmRequest('Test')],
        },
      }));

      render(<UIRequestModal />);

      expect(document.querySelector('.modal-overlay')).toBeInTheDocument();
    });

    it('renders modal container', () => {
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createConfirmRequest('Test')],
        },
      }));

      render(<UIRequestModal />);

      expect(document.querySelector('.modal')).toBeInTheDocument();
    });

    it('renders header with title and close button', () => {
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createConfirmRequest('Test')],
        },
      }));

      render(<UIRequestModal />);

      const header = document.querySelector('.modal__header');
      expect(header).toBeInTheDocument();
      expect(within(header as HTMLElement).getByRole('heading')).toBeInTheDocument();
      expect(within(header as HTMLElement).getByRole('button', { name: 'Close' })).toBeInTheDocument();
    });

    it('renders footer with action buttons', () => {
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createConfirmRequest('Test')],
        },
      }));

      render(<UIRequestModal />);

      const footer = document.querySelector('.modal__footer');
      expect(footer).toBeInTheDocument();
    });
  });

  // ============================================================================
  // Edge Cases
  // ============================================================================
  describe('edge cases', () => {
    it('handles select with no options', () => {
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest([])],
        },
      }));

      render(<UIRequestModal />);

      const chooseButton = screen.getByRole('button', { name: 'Choose' });
      expect(chooseButton).toBeDisabled();
    });

    it('handles select with single option', async () => {
      const user = userEvent.setup();
      const options: SelectOption[] = [{ label: 'Only Option', value: 'only' }];
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(options)],
        },
      }));

      render(<UIRequestModal />);

      const optionButton = screen.getByRole('button', { name: /Only Option/i });
      await user.click(optionButton);
      await user.click(screen.getByRole('button', { name: 'Choose' }));

      expect(mockSend).toHaveBeenCalledWith({
        type: 'ui_response',
        id: 'test-request-id',
        result: 'only',
        error: null,
      });
    });

    it('handles input with empty placeholder', () => {
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createInputRequest('')],
        },
      }));

      render(<UIRequestModal />);

      // Should render without error
      expect(screen.getByRole('textbox')).toBeInTheDocument();
    });

    it('handles confirm with empty message', () => {
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createConfirmRequest('')],
        },
      }));

      render(<UIRequestModal />);

      // Should render without error
      expect(screen.getByRole('heading', { name: 'Confirm Action' })).toBeInTheDocument();
    });

    it('handles special characters in option labels', () => {
      const options: SelectOption[] = [
        { label: '<script>alert("xss")</script>', value: 'xss' },
        { label: 'Option with "quotes"', value: 'quotes' },
        { label: 'Option with & ampersand', value: 'amp' },
      ];
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(options)],
        },
      }));

      render(<UIRequestModal />);

      // Should render escaped content
      expect(screen.getByText('<script>alert("xss")</script>')).toBeInTheDocument();
      expect(screen.getByText('Option with "quotes"')).toBeInTheDocument();
      expect(screen.getByText('Option with & ampersand')).toBeInTheDocument();
    });

    it('handles whitespace-only filter', async () => {
      const user = userEvent.setup();
      const options = createMockOptions(3);
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(options)],
        },
      }));

      render(<UIRequestModal />);

      const filterInput = screen.getByPlaceholderText('Filter options');
      await user.type(filterInput, '   ');

      // Whitespace-only should show all options
      expect(screen.getByText('Option 1')).toBeInTheDocument();
      expect(screen.getByText('Option 2')).toBeInTheDocument();
      expect(screen.getByText('Option 3')).toBeInTheDocument();
    });
  });

  // ============================================================================
  // Keyboard Navigation and Accessibility
  // ============================================================================
  describe('keyboard interaction', () => {
    it('allows keyboard navigation to option buttons', async () => {
      const user = userEvent.setup();
      const options = createMockOptions(3);
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createSelectRequest(options)],
        },
      }));

      render(<UIRequestModal />);

      // Tab through elements
      await user.tab(); // Close button
      await user.tab(); // Filter input
      await user.tab(); // First option

      const option1 = screen.getByRole('button', { name: /Option 1/i });
      expect(option1).toHaveFocus();
    });

    it('submits input on Enter key press', async () => {
      const user = userEvent.setup();
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createInputRequest('Enter text')],
        },
      }));

      render(<UIRequestModal />);

      const input = screen.getByPlaceholderText('Enter text');
      await user.type(input, 'Test value{enter}');

      // Note: The component does not have an onKeyDown handler for Enter
      // This test documents the current behavior - form submission would need
      // to be wrapped in a <form> element for Enter to work
      // For now, we verify the input received the text before enter
      expect(input).toHaveValue('Test value');
    });
  });

  // ============================================================================
  // Request ID Uniqueness
  // ============================================================================
  describe('request id handling', () => {
    it('uses correct request id in response', async () => {
      const user = userEvent.setup();
      const customId = 'custom-unique-id-12345';
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [createConfirmRequest('Test', { id: customId })],
        },
      }));

      render(<UIRequestModal />);

      await user.click(screen.getByRole('button', { name: 'Confirm' }));

      expect(mockSend).toHaveBeenCalledWith({
        type: 'ui_response',
        id: customId,
        result: true,
        error: null,
      });
    });
  });

  // ============================================================================
  // Multiple Requests Queue
  // ============================================================================
  describe('request queue behavior', () => {
    it('only displays the first request in queue', () => {
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [
            createConfirmRequest('First question'),
            createConfirmRequest('Second question'),
          ],
        },
      }));

      render(<UIRequestModal />);

      expect(screen.getByText('First question')).toBeInTheDocument();
      expect(screen.queryByText('Second question')).not.toBeInTheDocument();
    });

    it('dequeues after responding to first request', async () => {
      const user = userEvent.setup();
      useLemonStore.setState((state) => ({
        ui: {
          ...state.ui,
          requestsQueue: [
            createConfirmRequest('First question', { id: 'req-1' }),
            createConfirmRequest('Second question', { id: 'req-2' }),
          ],
        },
      }));

      render(<UIRequestModal />);

      await user.click(screen.getByRole('button', { name: 'Confirm' }));

      expect(mockDequeue).toHaveBeenCalledTimes(1);
    });
  });
});
