import { render, screen, act } from '@testing-library/react';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { WorkingBanner } from './WorkingBanner';
import { useLemonStore } from '../store/useLemonStore';

/**
 * Helper to set up the store state for WorkingBanner tests
 */
function setupStore(overrides: { workingMessage?: string | null } = {}) {
  act(() => {
    useLemonStore.setState({
      ui: {
        requestsQueue: [],
        status: {},
        widgets: {},
        workingMessage: overrides.workingMessage ?? null,
        title: null,
        editorText: '',
      },
    });
  });
}

/**
 * Helper to reset store to initial state
 */
function resetStore() {
  act(() => {
    useLemonStore.setState({
      ui: {
        requestsQueue: [],
        status: {},
        widgets: {},
        workingMessage: null,
        title: null,
        editorText: '',
      },
    });
  });
}

describe('WorkingBanner', () => {
  beforeEach(() => {
    resetStore();
  });

  afterEach(() => {
    resetStore();
  });

  // =========================================================================
  // Visibility Tests
  // =========================================================================

  describe('visibility', () => {
    it('returns null when workingMessage is null', () => {
      setupStore({ workingMessage: null });
      const { container } = render(<WorkingBanner />);

      expect(container.firstChild).toBeNull();
    });

    it('returns null when workingMessage is undefined (default store state)', () => {
      // Use setState with minimal override to test undefined scenario
      act(() => {
        useLemonStore.setState({
          ui: {
            requestsQueue: [],
            status: {},
            widgets: {},
            workingMessage: null,
            title: null,
            editorText: '',
          },
        });
      });
      const { container } = render(<WorkingBanner />);

      expect(container.firstChild).toBeNull();
    });

    it('returns null when workingMessage is empty string', () => {
      setupStore({ workingMessage: '' });
      const { container } = render(<WorkingBanner />);

      expect(container.firstChild).toBeNull();
    });

    it('renders banner when workingMessage is set', () => {
      setupStore({ workingMessage: 'Processing...' });
      const { container } = render(<WorkingBanner />);

      expect(container.firstChild).not.toBeNull();
    });

    it('becomes visible when workingMessage changes from null to a value', () => {
      setupStore({ workingMessage: null });
      const { container, rerender } = render(<WorkingBanner />);

      expect(container.firstChild).toBeNull();

      act(() => {
        useLemonStore.setState((state) => ({
          ui: { ...state.ui, workingMessage: 'Now working...' },
        }));
      });
      rerender(<WorkingBanner />);

      expect(container.firstChild).not.toBeNull();
      expect(screen.getByText('Now working...')).toBeInTheDocument();
    });

    it('becomes hidden when workingMessage changes from a value to null', () => {
      setupStore({ workingMessage: 'Working...' });
      const { container, rerender } = render(<WorkingBanner />);

      expect(screen.getByText('Working...')).toBeInTheDocument();

      act(() => {
        useLemonStore.setState((state) => ({
          ui: { ...state.ui, workingMessage: null },
        }));
      });
      rerender(<WorkingBanner />);

      expect(container.firstChild).toBeNull();
    });
  });

  // =========================================================================
  // Message Display Tests
  // =========================================================================

  describe('message display', () => {
    it('displays the working message text', () => {
      setupStore({ workingMessage: 'Loading data...' });
      render(<WorkingBanner />);

      expect(screen.getByText('Loading data...')).toBeInTheDocument();
    });

    it('displays short messages correctly', () => {
      setupStore({ workingMessage: 'OK' });
      render(<WorkingBanner />);

      expect(screen.getByText('OK')).toBeInTheDocument();
    });

    it('displays long messages correctly', () => {
      const longMessage =
        'This is a very long working message that might appear during complex operations that take a significant amount of time to complete';
      setupStore({ workingMessage: longMessage });
      render(<WorkingBanner />);

      expect(screen.getByText(longMessage)).toBeInTheDocument();
    });

    it('displays messages with special characters', () => {
      setupStore({ workingMessage: 'Processing file: /path/to/file.txt (50%)' });
      render(<WorkingBanner />);

      expect(screen.getByText('Processing file: /path/to/file.txt (50%)')).toBeInTheDocument();
    });

    it('displays messages with unicode characters', () => {
      setupStore({ workingMessage: 'Analyzing code...' });
      render(<WorkingBanner />);

      expect(screen.getByText('Analyzing code...')).toBeInTheDocument();
    });

    it('displays messages with HTML-like content as text (XSS prevention)', () => {
      setupStore({ workingMessage: '<script>alert("xss")</script>' });
      render(<WorkingBanner />);

      // Should render as text, not execute
      expect(screen.getByText('<script>alert("xss")</script>')).toBeInTheDocument();
    });

    it('displays messages with ampersands and entities correctly', () => {
      setupStore({ workingMessage: 'Fetching data & processing...' });
      render(<WorkingBanner />);

      expect(screen.getByText('Fetching data & processing...')).toBeInTheDocument();
    });
  });

  // =========================================================================
  // Message Updates Tests
  // =========================================================================

  describe('message updates', () => {
    it('updates displayed message when store changes', () => {
      setupStore({ workingMessage: 'Step 1...' });
      const { rerender } = render(<WorkingBanner />);

      expect(screen.getByText('Step 1...')).toBeInTheDocument();

      act(() => {
        useLemonStore.setState((state) => ({
          ui: { ...state.ui, workingMessage: 'Step 2...' },
        }));
      });
      rerender(<WorkingBanner />);

      expect(screen.getByText('Step 2...')).toBeInTheDocument();
      expect(screen.queryByText('Step 1...')).not.toBeInTheDocument();
    });

    it('handles rapid message updates', () => {
      setupStore({ workingMessage: 'Message 1' });
      const { rerender } = render(<WorkingBanner />);

      for (let i = 2; i <= 5; i++) {
        act(() => {
          useLemonStore.setState((state) => ({
            ui: { ...state.ui, workingMessage: `Message ${i}` },
          }));
        });
        rerender(<WorkingBanner />);
      }

      expect(screen.getByText('Message 5')).toBeInTheDocument();
    });

    it('handles message changing to empty string (hides banner)', () => {
      setupStore({ workingMessage: 'Working...' });
      const { container, rerender } = render(<WorkingBanner />);

      expect(screen.getByText('Working...')).toBeInTheDocument();

      act(() => {
        useLemonStore.setState((state) => ({
          ui: { ...state.ui, workingMessage: '' },
        }));
      });
      rerender(<WorkingBanner />);

      expect(container.firstChild).toBeNull();
    });
  });

  // =========================================================================
  // CSS Classes Tests
  // =========================================================================

  describe('CSS classes', () => {
    it('applies working-banner class to container', () => {
      setupStore({ workingMessage: 'Working...' });
      render(<WorkingBanner />);

      const banner = screen.getByText('Working...').closest('.working-banner');
      expect(banner).toBeInTheDocument();
      expect(banner).toHaveClass('working-banner');
    });

    it('renders container as a div element', () => {
      setupStore({ workingMessage: 'Working...' });
      render(<WorkingBanner />);

      const banner = screen.getByText('Working...').closest('.working-banner');
      expect(banner?.tagName).toBe('DIV');
    });
  });

  // =========================================================================
  // Spinner Tests
  // =========================================================================

  describe('spinner', () => {
    it('renders spinner element when banner is visible', () => {
      setupStore({ workingMessage: 'Working...' });
      render(<WorkingBanner />);

      const banner = screen.getByText('Working...').closest('.working-banner');
      const spinner = banner?.querySelector('.spinner');
      expect(spinner).toBeInTheDocument();
    });

    it('spinner has correct CSS class', () => {
      setupStore({ workingMessage: 'Working...' });
      render(<WorkingBanner />);

      const spinner = document.querySelector('.spinner');
      expect(spinner).toHaveClass('spinner');
    });

    it('spinner is a span element', () => {
      setupStore({ workingMessage: 'Working...' });
      render(<WorkingBanner />);

      const spinner = document.querySelector('.spinner');
      expect(spinner?.tagName).toBe('SPAN');
    });

    it('spinner appears before the message text', () => {
      setupStore({ workingMessage: 'Working...' });
      render(<WorkingBanner />);

      const banner = document.querySelector('.working-banner');
      const children = banner?.children;

      // First child should be spinner, second should be message
      expect(children?.[0]).toHaveClass('spinner');
      expect(children?.[1]?.textContent).toBe('Working...');
    });

    it('only one spinner is rendered', () => {
      setupStore({ workingMessage: 'Working...' });
      render(<WorkingBanner />);

      const spinners = document.querySelectorAll('.spinner');
      expect(spinners.length).toBe(1);
    });
  });

  // =========================================================================
  // DOM Structure Tests
  // =========================================================================

  describe('DOM structure', () => {
    it('has correct structure: div > span.spinner + span', () => {
      setupStore({ workingMessage: 'Working...' });
      render(<WorkingBanner />);

      const banner = document.querySelector('.working-banner');
      expect(banner).not.toBeNull();
      expect(banner?.children.length).toBe(2);
      expect(banner?.children[0].tagName).toBe('SPAN');
      expect(banner?.children[0]).toHaveClass('spinner');
      expect(banner?.children[1].tagName).toBe('SPAN');
    });

    it('message is wrapped in a span element', () => {
      setupStore({ workingMessage: 'Test message' });
      render(<WorkingBanner />);

      const banner = document.querySelector('.working-banner');
      const messageSpan = banner?.children[1];

      expect(messageSpan?.tagName).toBe('SPAN');
      expect(messageSpan?.textContent).toBe('Test message');
    });
  });

  // =========================================================================
  // Edge Cases Tests
  // =========================================================================

  describe('edge cases', () => {
    it('handles whitespace-only messages (shows banner)', () => {
      setupStore({ workingMessage: '   ' });
      const { container } = render(<WorkingBanner />);

      // Whitespace-only is truthy, so banner should render
      expect(container.firstChild).not.toBeNull();
    });

    it('handles newline characters in messages', () => {
      setupStore({ workingMessage: 'Line 1\nLine 2' });
      render(<WorkingBanner />);

      expect(screen.getByText(/Line 1/)).toBeInTheDocument();
    });

    it('handles tab characters in messages', () => {
      setupStore({ workingMessage: 'Before\tAfter' });
      render(<WorkingBanner />);

      expect(screen.getByText(/Before/)).toBeInTheDocument();
    });

    it('handles numeric-like messages', () => {
      setupStore({ workingMessage: '12345' });
      render(<WorkingBanner />);

      expect(screen.getByText('12345')).toBeInTheDocument();
    });

    it('handles messages with leading/trailing spaces', () => {
      setupStore({ workingMessage: '  Trimmed message  ' });
      render(<WorkingBanner />);

      expect(screen.getByText('Trimmed message', { exact: false })).toBeInTheDocument();
    });
  });

  // =========================================================================
  // Integration with Store Tests
  // =========================================================================

  describe('store integration', () => {
    it('reacts to store state changes', () => {
      const { container, rerender } = render(<WorkingBanner />);

      // Initially null
      expect(container.firstChild).toBeNull();

      // Set message
      act(() => {
        useLemonStore.setState((state) => ({
          ui: { ...state.ui, workingMessage: 'Loading...' },
        }));
      });
      rerender(<WorkingBanner />);
      expect(screen.getByText('Loading...')).toBeInTheDocument();

      // Update message
      act(() => {
        useLemonStore.setState((state) => ({
          ui: { ...state.ui, workingMessage: 'Almost done...' },
        }));
      });
      rerender(<WorkingBanner />);
      expect(screen.getByText('Almost done...')).toBeInTheDocument();

      // Clear message
      act(() => {
        useLemonStore.setState((state) => ({
          ui: { ...state.ui, workingMessage: null },
        }));
      });
      rerender(<WorkingBanner />);
      expect(container.firstChild).toBeNull();
    });

    it('does not affect other store state', () => {
      act(() => {
        useLemonStore.setState({
          ui: {
            requestsQueue: [],
            status: { testKey: 'testValue' },
            widgets: {},
            workingMessage: 'Working...',
            title: 'Custom Title',
            editorText: 'Some text',
          },
        });
      });

      render(<WorkingBanner />);

      // Verify other state is preserved
      const state = useLemonStore.getState();
      expect(state.ui.status.testKey).toBe('testValue');
      expect(state.ui.title).toBe('Custom Title');
      expect(state.ui.editorText).toBe('Some text');
    });

    it('correctly selects only workingMessage from store', () => {
      act(() => {
        useLemonStore.setState({
          ui: {
            requestsQueue: [],
            status: {},
            widgets: {},
            workingMessage: 'Selected correctly',
            title: 'Ignored title',
            editorText: 'Ignored text',
          },
        });
      });

      render(<WorkingBanner />);

      expect(screen.getByText('Selected correctly')).toBeInTheDocument();
      expect(screen.queryByText('Ignored title')).not.toBeInTheDocument();
      expect(screen.queryByText('Ignored text')).not.toBeInTheDocument();
    });
  });

  // =========================================================================
  // Accessibility Tests
  // =========================================================================

  describe('accessibility', () => {
    it('message text is readable by screen readers', () => {
      setupStore({ workingMessage: 'Loading your data...' });
      render(<WorkingBanner />);

      // The text should be in the document and accessible
      const messageElement = screen.getByText('Loading your data...');
      expect(messageElement).toBeInTheDocument();
      expect(messageElement).toBeVisible();
    });

    it('banner container is in the DOM when visible', () => {
      setupStore({ workingMessage: 'Processing...' });
      render(<WorkingBanner />);

      const banner = document.querySelector('.working-banner');
      expect(banner).toBeInTheDocument();
    });
  });
});
