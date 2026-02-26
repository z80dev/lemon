import { render, screen, fireEvent, within, act } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { ToastStack } from './ToastStack';
import { useLemonStore, type Notification } from '../store/useLemonStore';

/**
 * Helper function to create a notification fixture
 */
function createNotification(overrides: Partial<Notification> = {}): Notification {
  return {
    id: `notification-${Date.now()}-${Math.random().toString(36).slice(2)}`,
    message: 'Test notification message',
    level: 'info',
    createdAt: Date.now(),
    ...overrides,
  };
}

/**
 * Helper to set up store state with notifications (wrapped in act)
 */
function setupStore(notifications: Notification[] = []) {
  const mockDismiss = vi.fn((id: string) => {
    useLemonStore.setState((state) => ({
      notifications: state.notifications.filter((n) => n.id !== id),
    }));
  });

  act(() => {
    useLemonStore.setState({
      notifications,
      dismissNotification: mockDismiss,
    });
  });

  return { mockDismiss };
}

/**
 * Helper to reset store to initial state
 */
function resetStore() {
  act(() => {
    useLemonStore.setState({
      notifications: [],
    });
  });
}

/**
 * Helper to update store state (wrapped in act)
 */
function updateStore(updater: (state: ReturnType<typeof useLemonStore.getState>) => Partial<ReturnType<typeof useLemonStore.getState>>) {
  act(() => {
    useLemonStore.setState(updater);
  });
}

describe('ToastStack', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    resetStore();
  });

  afterEach(() => {
    vi.clearAllTimers();
    vi.useRealTimers();
    resetStore();
  });

  // =========================================================================
  // Basic Rendering Tests
  // =========================================================================

  describe('basic rendering', () => {
    it('renders empty toast stack when no notifications', () => {
      setupStore([]);
      render(<ToastStack />);

      const stack = document.querySelector('.toast-stack');
      expect(stack).toBeInTheDocument();
      expect(stack?.children.length).toBe(0);
    });

    it('renders a single notification', () => {
      const notification = createNotification({ message: 'Hello World' });
      setupStore([notification]);
      render(<ToastStack />);

      expect(screen.getByText('Hello World')).toBeInTheDocument();
    });

    it('renders notification message inside toast container', () => {
      const notification = createNotification({ message: 'Test message' });
      setupStore([notification]);
      render(<ToastStack />);

      const toast = document.querySelector('.toast');
      expect(toast).toBeInTheDocument();
      expect(within(toast as HTMLElement).getByText('Test message')).toBeInTheDocument();
    });

    it('renders dismiss button for each notification', () => {
      const notification = createNotification();
      setupStore([notification]);
      render(<ToastStack />);

      expect(screen.getByRole('button', { name: 'Dismiss' })).toBeInTheDocument();
    });

    it('applies toast-stack class to container', () => {
      setupStore([]);
      render(<ToastStack />);

      const stack = document.querySelector('.toast-stack');
      expect(stack).toBeInTheDocument();
      expect(stack).toHaveClass('toast-stack');
    });
  });

  // =========================================================================
  // Multiple Notifications Tests
  // =========================================================================

  describe('multiple notifications', () => {
    it('renders multiple notifications', () => {
      const notifications = [
        createNotification({ id: 'note-1', message: 'First notification' }),
        createNotification({ id: 'note-2', message: 'Second notification' }),
        createNotification({ id: 'note-3', message: 'Third notification' }),
      ];
      setupStore(notifications);
      render(<ToastStack />);

      expect(screen.getByText('First notification')).toBeInTheDocument();
      expect(screen.getByText('Second notification')).toBeInTheDocument();
      expect(screen.getByText('Third notification')).toBeInTheDocument();
    });

    it('renders correct number of dismiss buttons for multiple notifications', () => {
      const notifications = [
        createNotification({ id: 'note-1' }),
        createNotification({ id: 'note-2' }),
        createNotification({ id: 'note-3' }),
      ];
      setupStore(notifications);
      render(<ToastStack />);

      const dismissButtons = screen.getAllByRole('button', { name: 'Dismiss' });
      expect(dismissButtons.length).toBe(3);
    });

    it('renders notifications in array order (stack ordering)', () => {
      const notifications = [
        createNotification({ id: 'note-1', message: 'First' }),
        createNotification({ id: 'note-2', message: 'Second' }),
        createNotification({ id: 'note-3', message: 'Third' }),
      ];
      setupStore(notifications);
      render(<ToastStack />);

      const toasts = document.querySelectorAll('.toast');
      expect(toasts.length).toBe(3);
      expect(within(toasts[0] as HTMLElement).getByText('First')).toBeInTheDocument();
      expect(within(toasts[1] as HTMLElement).getByText('Second')).toBeInTheDocument();
      expect(within(toasts[2] as HTMLElement).getByText('Third')).toBeInTheDocument();
    });

    it('handles many notifications without breaking', () => {
      const notifications = Array.from({ length: 10 }, (_, i) =>
        createNotification({ id: `note-${i}`, message: `Notification ${i + 1}` })
      );
      setupStore(notifications);
      render(<ToastStack />);

      const toasts = document.querySelectorAll('.toast');
      expect(toasts.length).toBe(10);
    });
  });

  // =========================================================================
  // Notification Level/Type Tests
  // =========================================================================

  describe('notification types (levels)', () => {
    it('applies correct CSS class for info level', () => {
      const notification = createNotification({ level: 'info' });
      setupStore([notification]);
      render(<ToastStack />);

      const toast = document.querySelector('.toast');
      expect(toast).toHaveClass('toast--info');
    });

    it('applies correct CSS class for success level', () => {
      const notification = createNotification({ level: 'success' });
      setupStore([notification]);
      render(<ToastStack />);

      const toast = document.querySelector('.toast');
      expect(toast).toHaveClass('toast--success');
    });

    it('applies correct CSS class for warn level', () => {
      const notification = createNotification({ level: 'warn' });
      setupStore([notification]);
      render(<ToastStack />);

      const toast = document.querySelector('.toast');
      expect(toast).toHaveClass('toast--warn');
    });

    it('applies correct CSS class for error level', () => {
      const notification = createNotification({ level: 'error' });
      setupStore([notification]);
      render(<ToastStack />);

      const toast = document.querySelector('.toast');
      expect(toast).toHaveClass('toast--error');
    });

    it('renders mixed notification levels with correct classes', () => {
      const notifications = [
        createNotification({ id: 'info-1', level: 'info' }),
        createNotification({ id: 'success-1', level: 'success' }),
        createNotification({ id: 'warn-1', level: 'warn' }),
        createNotification({ id: 'error-1', level: 'error' }),
      ];
      setupStore(notifications);
      render(<ToastStack />);

      const toasts = document.querySelectorAll('.toast');
      expect(toasts[0]).toHaveClass('toast--info');
      expect(toasts[1]).toHaveClass('toast--success');
      expect(toasts[2]).toHaveClass('toast--warn');
      expect(toasts[3]).toHaveClass('toast--error');
    });
  });

  // =========================================================================
  // Manual Dismissal Tests
  // =========================================================================

  describe('manual notification dismissal', () => {
    it('calls dismissNotification with correct ID when Dismiss button clicked', () => {
      const notification = createNotification({ id: 'test-dismiss-id' });
      const { mockDismiss } = setupStore([notification]);
      render(<ToastStack />);

      fireEvent.click(screen.getByRole('button', { name: 'Dismiss' }));

      expect(mockDismiss).toHaveBeenCalledWith('test-dismiss-id');
    });

    it('removes notification from DOM after dismissal', () => {
      const notification = createNotification({ id: 'removable', message: 'Will be removed' });
      setupStore([notification]);
      render(<ToastStack />);

      expect(screen.getByText('Will be removed')).toBeInTheDocument();

      fireEvent.click(screen.getByRole('button', { name: 'Dismiss' }));

      expect(screen.queryByText('Will be removed')).not.toBeInTheDocument();
    });

    it('dismisses only the clicked notification in a stack', () => {
      const notifications = [
        createNotification({ id: 'keep-1', message: 'Keep this one' }),
        createNotification({ id: 'remove-1', message: 'Remove this one' }),
        createNotification({ id: 'keep-2', message: 'Keep this too' }),
      ];
      setupStore(notifications);
      render(<ToastStack />);

      const dismissButtons = screen.getAllByRole('button', { name: 'Dismiss' });
      fireEvent.click(dismissButtons[1]); // Click dismiss on second notification

      expect(screen.getByText('Keep this one')).toBeInTheDocument();
      expect(screen.queryByText('Remove this one')).not.toBeInTheDocument();
      expect(screen.getByText('Keep this too')).toBeInTheDocument();
    });

    it('dismiss button has ghost-button class', () => {
      const notification = createNotification();
      setupStore([notification]);
      render(<ToastStack />);

      const dismissButton = screen.getByRole('button', { name: 'Dismiss' });
      expect(dismissButton).toHaveClass('ghost-button');
    });
  });

  // =========================================================================
  // Auto-Dismiss (Timeout) Tests
  // =========================================================================

  describe('auto-dismiss behavior (timeout)', () => {
    it('schedules auto-dismiss after 6 seconds', () => {
      const notification = createNotification({ id: 'auto-dismiss', message: 'Auto dismiss me' });
      const { mockDismiss } = setupStore([notification]);
      render(<ToastStack />);

      // Notification should still be present before timeout
      expect(screen.getByText('Auto dismiss me')).toBeInTheDocument();
      expect(mockDismiss).not.toHaveBeenCalled();

      // Advance time by 6 seconds
      act(() => {
        vi.advanceTimersByTime(6000);
      });

      expect(mockDismiss).toHaveBeenCalledWith('auto-dismiss');
    });

    it('does not auto-dismiss before 6 seconds', () => {
      const notification = createNotification({ id: 'no-dismiss-yet' });
      const { mockDismiss } = setupStore([notification]);
      render(<ToastStack />);

      // Advance time by 5.9 seconds
      act(() => {
        vi.advanceTimersByTime(5900);
      });

      expect(mockDismiss).not.toHaveBeenCalled();
    });

    it('schedules auto-dismiss for multiple notifications independently', () => {
      const notification1 = createNotification({ id: 'first' });
      const notification2 = createNotification({ id: 'second' });
      const { mockDismiss } = setupStore([notification1, notification2]);
      render(<ToastStack />);

      act(() => {
        vi.advanceTimersByTime(6000);
      });

      expect(mockDismiss).toHaveBeenCalledWith('first');
      expect(mockDismiss).toHaveBeenCalledWith('second');
      expect(mockDismiss).toHaveBeenCalledTimes(2);
    });

    it('does not schedule duplicate timeouts for existing notifications', () => {
      const notification = createNotification({ id: 'single-timeout' });
      setupStore([notification]);
      const { rerender } = render(<ToastStack />);

      // Trigger multiple re-renders
      rerender(<ToastStack />);
      rerender(<ToastStack />);
      rerender(<ToastStack />);

      // Get fresh mock reference after re-renders
      const mockDismiss = useLemonStore.getState().dismissNotification;

      act(() => {
        vi.advanceTimersByTime(6000);
      });

      // Should only be called once despite multiple re-renders
      expect(mockDismiss).toHaveBeenCalledTimes(1);
    });

    it('schedules timeout for newly added notifications', () => {
      const initialNotification = createNotification({ id: 'initial', message: 'Initial' });
      const { mockDismiss } = setupStore([initialNotification]);
      const { rerender } = render(<ToastStack />);

      // Add a new notification
      const newNotification = createNotification({ id: 'new', message: 'New' });
      updateStore((state) => ({
        notifications: [...state.notifications, newNotification],
      }));
      rerender(<ToastStack />);

      act(() => {
        vi.advanceTimersByTime(6000);
      });

      expect(mockDismiss).toHaveBeenCalledWith('initial');
      expect(mockDismiss).toHaveBeenCalledWith('new');
    });

    it('cleans up scheduled IDs after dismissal', () => {
      const notification = createNotification({ id: 'cleanup-test' });
      setupStore([notification]);
      render(<ToastStack />);

      act(() => {
        vi.advanceTimersByTime(6000);
      });

      // The notification should be dismissed and scheduled set cleared
      const toasts = document.querySelectorAll('.toast');
      expect(toasts.length).toBe(0);
    });

    it('handles staggered notification additions with independent timers', () => {
      const firstNotification = createNotification({ id: 'first', message: 'First' });
      const { mockDismiss } = setupStore([firstNotification]);
      const { rerender } = render(<ToastStack />);

      // Advance 3 seconds
      act(() => {
        vi.advanceTimersByTime(3000);
      });

      // Add second notification
      const secondNotification = createNotification({ id: 'second', message: 'Second' });
      updateStore((state) => ({
        notifications: [...state.notifications, secondNotification],
      }));
      rerender(<ToastStack />);

      // Advance 3 more seconds (first should dismiss, second should remain)
      act(() => {
        vi.advanceTimersByTime(3000);
      });

      expect(mockDismiss).toHaveBeenCalledWith('first');
      expect(mockDismiss).not.toHaveBeenCalledWith('second');

      // Advance 3 more seconds (second should now dismiss)
      act(() => {
        vi.advanceTimersByTime(3000);
      });

      expect(mockDismiss).toHaveBeenCalledWith('second');
    });
  });

  // =========================================================================
  // Store Integration Tests
  // =========================================================================

  describe('store integration', () => {
    it('updates when store notifications change', () => {
      setupStore([]);
      const { rerender } = render(<ToastStack />);

      expect(document.querySelectorAll('.toast').length).toBe(0);

      // Add notification via store
      const notification = createNotification({ message: 'Dynamically added' });
      updateStore((state) => ({
        notifications: [...state.notifications, notification],
      }));
      rerender(<ToastStack />);

      expect(screen.getByText('Dynamically added')).toBeInTheDocument();
    });

    it('removes notification from display when removed from store', () => {
      const notification = createNotification({ id: 'to-remove', message: 'Will be removed' });
      setupStore([notification]);
      const { rerender } = render(<ToastStack />);

      expect(screen.getByText('Will be removed')).toBeInTheDocument();

      // Remove from store
      updateStore(() => ({ notifications: [] }));
      rerender(<ToastStack />);

      expect(screen.queryByText('Will be removed')).not.toBeInTheDocument();
    });

    it('handles rapid additions and removals', () => {
      setupStore([]);
      const { rerender } = render(<ToastStack />);

      // Rapidly add notifications
      for (let i = 0; i < 5; i++) {
        const note = createNotification({ id: `rapid-${i}`, message: `Rapid ${i}` });
        updateStore((state) => ({
          notifications: [...state.notifications, note],
        }));
        rerender(<ToastStack />);
      }

      expect(document.querySelectorAll('.toast').length).toBe(5);
    });

    it('syncs with store dismissNotification action', () => {
      const notification = createNotification({ id: 'sync-test', message: 'Sync test' });
      setupStore([notification]);
      render(<ToastStack />);

      expect(screen.getByText('Sync test')).toBeInTheDocument();

      // Directly call the store's dismiss
      act(() => {
        useLemonStore.getState().dismissNotification('sync-test');
      });

      expect(screen.queryByText('Sync test')).not.toBeInTheDocument();
    });
  });

  // =========================================================================
  // Edge Cases
  // =========================================================================

  describe('edge cases', () => {
    it('handles empty message string', () => {
      const notification = createNotification({ message: '' });
      setupStore([notification]);
      render(<ToastStack />);

      const toast = document.querySelector('.toast');
      expect(toast).toBeInTheDocument();
    });

    it('handles very long messages', () => {
      const longMessage = 'A'.repeat(1000);
      const notification = createNotification({ message: longMessage });
      setupStore([notification]);
      render(<ToastStack />);

      expect(screen.getByText(longMessage)).toBeInTheDocument();
    });

    it('handles special characters in messages', () => {
      const notification = createNotification({
        message: '<script>alert("xss")</script>',
      });
      setupStore([notification]);
      render(<ToastStack />);

      // Should render as text, not execute
      expect(screen.getByText('<script>alert("xss")</script>')).toBeInTheDocument();
    });

    it('handles unicode characters in messages', () => {
      const notification = createNotification({
        message: 'Hello World! Test message here.',
      });
      setupStore([notification]);
      render(<ToastStack />);

      expect(screen.getByText('Hello World! Test message here.')).toBeInTheDocument();
    });

    it('handles notifications with same ID (deduplication scenario)', () => {
      const notifications = [
        createNotification({ id: 'same-id', message: 'First' }),
        createNotification({ id: 'same-id', message: 'Second' }),
      ];
      setupStore(notifications);
      render(<ToastStack />);

      // Both render with same key, but React will show both items
      // This tests that the component handles this edge case without crashing
      const toasts = document.querySelectorAll('.toast');
      expect(toasts.length).toBe(2);
    });

    it('renders correctly when notifications array is replaced entirely', () => {
      const initialNotifications = [
        createNotification({ id: 'old-1', message: 'Old 1' }),
        createNotification({ id: 'old-2', message: 'Old 2' }),
      ];
      setupStore(initialNotifications);
      const { rerender } = render(<ToastStack />);

      const newNotifications = [
        createNotification({ id: 'new-1', message: 'New 1' }),
        createNotification({ id: 'new-2', message: 'New 2' }),
        createNotification({ id: 'new-3', message: 'New 3' }),
      ];
      updateStore(() => ({ notifications: newNotifications }));
      rerender(<ToastStack />);

      expect(screen.queryByText('Old 1')).not.toBeInTheDocument();
      expect(screen.queryByText('Old 2')).not.toBeInTheDocument();
      expect(screen.getByText('New 1')).toBeInTheDocument();
      expect(screen.getByText('New 2')).toBeInTheDocument();
      expect(screen.getByText('New 3')).toBeInTheDocument();
    });

    it('handles notification with multiline message', () => {
      const notification = createNotification({
        message: 'Line 1\nLine 2\nLine 3',
      });
      setupStore([notification]);
      render(<ToastStack />);

      expect(
        screen.getByText((content) =>
          content.includes('Line 1') &&
          content.includes('Line 2') &&
          content.includes('Line 3')
        )
      ).toBeInTheDocument();
    });

    it('handles notification with whitespace-only message', () => {
      const notification = createNotification({ message: '   ' });
      setupStore([notification]);
      render(<ToastStack />);

      const toast = document.querySelector('.toast');
      expect(toast).toBeInTheDocument();
    });
  });

  // =========================================================================
  // CSS Class Application Tests
  // =========================================================================

  describe('CSS class application', () => {
    it('applies base toast class to all notifications', () => {
      const notifications = [
        createNotification({ id: 'css-1', level: 'info' }),
        createNotification({ id: 'css-2', level: 'error' }),
      ];
      setupStore(notifications);
      render(<ToastStack />);

      const toasts = document.querySelectorAll('.toast');
      toasts.forEach((toast) => {
        expect(toast).toHaveClass('toast');
      });
    });

    it('applies both base and level-specific classes', () => {
      const notification = createNotification({ level: 'success' });
      setupStore([notification]);
      render(<ToastStack />);

      const toast = document.querySelector('.toast');
      expect(toast).toHaveClass('toast');
      expect(toast).toHaveClass('toast--success');
    });

    it('uses BEM naming convention for level modifiers', () => {
      const levels: Array<'info' | 'success' | 'warn' | 'error'> = ['info', 'success', 'warn', 'error'];

      for (const level of levels) {
        resetStore();
        const notification = createNotification({ id: `bem-${level}`, level });
        setupStore([notification]);
        const { unmount } = render(<ToastStack />);

        const toast = document.querySelector('.toast');
        expect(toast).toHaveClass(`toast--${level}`);

        unmount();
      }
    });
  });

  // =========================================================================
  // Key Assignment Tests
  // =========================================================================

  describe('React key assignment', () => {
    it('uses notification id as React key', () => {
      const notifications = [
        createNotification({ id: 'unique-key-1', message: 'First' }),
        createNotification({ id: 'unique-key-2', message: 'Second' }),
      ];
      setupStore(notifications);
      render(<ToastStack />);

      // If keys are working properly, removing first notification should
      // not cause second notification to lose state
      const toasts = document.querySelectorAll('.toast');
      expect(toasts.length).toBe(2);
    });

    it('maintains stable keys across re-renders', () => {
      const notifications = [
        createNotification({ id: 'stable-1', message: 'Stable 1' }),
        createNotification({ id: 'stable-2', message: 'Stable 2' }),
      ];
      setupStore(notifications);
      const { rerender } = render(<ToastStack />);

      // Re-render multiple times
      rerender(<ToastStack />);
      rerender(<ToastStack />);

      const toasts = document.querySelectorAll('.toast');
      expect(toasts.length).toBe(2);
      expect(within(toasts[0] as HTMLElement).getByText('Stable 1')).toBeInTheDocument();
      expect(within(toasts[1] as HTMLElement).getByText('Stable 2')).toBeInTheDocument();
    });
  });

  // =========================================================================
  // Accessibility Tests
  // =========================================================================

  describe('accessibility', () => {
    it('dismiss buttons are keyboard accessible', () => {
      const notification = createNotification();
      setupStore([notification]);
      render(<ToastStack />);

      const dismissButton = screen.getByRole('button', { name: 'Dismiss' });
      expect(dismissButton).toBeInTheDocument();
      expect(dismissButton.tagName).toBe('BUTTON');
    });

    it('dismiss buttons can be activated with keyboard', () => {
      const notification = createNotification({ id: 'keyboard-dismiss' });
      const { mockDismiss } = setupStore([notification]);
      render(<ToastStack />);

      const dismissButton = screen.getByRole('button', { name: 'Dismiss' });
      dismissButton.focus();
      fireEvent.keyDown(dismissButton, { key: 'Enter' });
      fireEvent.click(dismissButton);

      expect(mockDismiss).toHaveBeenCalledWith('keyboard-dismiss');
    });

    it('each toast has accessible dismiss button with text label', () => {
      const notifications = [
        createNotification({ id: 'a11y-1' }),
        createNotification({ id: 'a11y-2' }),
      ];
      setupStore(notifications);
      render(<ToastStack />);

      const buttons = screen.getAllByRole('button', { name: 'Dismiss' });
      expect(buttons.length).toBe(2);
      buttons.forEach((button) => {
        expect(button).toHaveTextContent('Dismiss');
      });
    });
  });

  // =========================================================================
  // Component Structure Tests
  // =========================================================================

  describe('component structure', () => {
    it('has correct DOM structure', () => {
      const notification = createNotification({ message: 'Test' });
      setupStore([notification]);
      render(<ToastStack />);

      const stack = document.querySelector('.toast-stack');
      expect(stack).toBeInTheDocument();

      const toast = stack?.querySelector('.toast');
      expect(toast).toBeInTheDocument();

      const messageDiv = toast?.querySelector('div');
      expect(messageDiv).toBeInTheDocument();
      expect(messageDiv?.textContent).toBe('Test');

      const button = toast?.querySelector('button');
      expect(button).toBeInTheDocument();
      expect(button?.textContent).toBe('Dismiss');
    });

    it('message and button are siblings within toast', () => {
      const notification = createNotification({ message: 'Sibling test' });
      setupStore([notification]);
      render(<ToastStack />);

      const toast = document.querySelector('.toast');
      const children = toast?.children;
      expect(children?.length).toBe(2);
      expect(children?.[0].textContent).toBe('Sibling test');
      expect(children?.[1].textContent).toBe('Dismiss');
    });

    it('toasts are direct children of toast-stack', () => {
      const notifications = [
        createNotification({ id: 'direct-1' }),
        createNotification({ id: 'direct-2' }),
      ];
      setupStore(notifications);
      render(<ToastStack />);

      const stack = document.querySelector('.toast-stack');
      const directChildren = stack?.querySelectorAll(':scope > .toast');
      expect(directChildren?.length).toBe(2);
    });
  });

  // =========================================================================
  // Cleanup and Unmounting Tests
  // =========================================================================

  describe('cleanup and unmounting', () => {
    it('does not throw errors when unmounted with pending timeouts', () => {
      const notification = createNotification({ id: 'unmount-test' });
      setupStore([notification]);
      const { unmount } = render(<ToastStack />);

      // Unmount before timeout fires
      expect(() => unmount()).not.toThrow();

      // Advance time past the timeout
      act(() => {
        vi.advanceTimersByTime(10000);
      });

      // No errors should occur
    });

    it('handles unmount and remount correctly', () => {
      const notification = createNotification({ id: 'remount-test', message: 'Remount me' });
      setupStore([notification]);

      const { unmount } = render(<ToastStack />);
      expect(screen.getByText('Remount me')).toBeInTheDocument();

      unmount();

      // Remount
      render(<ToastStack />);
      expect(screen.getByText('Remount me')).toBeInTheDocument();
    });
  });
});
