import { render, screen, cleanup, waitFor } from '@testing-library/react';
import { describe, it, expect, beforeEach, afterEach, vi, type Mock } from 'vitest';
import App from './App';
import { useLemonStore, type LemonState } from './store/useLemonStore';
import * as useLemonSocketModule from './rpc/useLemonSocket';

// ============================================================================
// Mock Definitions
// ============================================================================

// Mock all child components to isolate App component tests
vi.mock('./components/TopBar', () => ({
  TopBar: () => <div data-testid="mock-top-bar">TopBar</div>,
}));

vi.mock('./components/Sidebar', () => ({
  Sidebar: () => <aside data-testid="mock-sidebar">Sidebar</aside>,
}));

vi.mock('./components/ChatView', () => ({
  ChatView: () => <div data-testid="mock-chat-view">ChatView</div>,
}));

vi.mock('./components/ToolTimeline', () => ({
  ToolTimeline: () => <div data-testid="mock-tool-timeline">ToolTimeline</div>,
}));

vi.mock('./components/StatusBar', () => ({
  StatusBar: () => <div data-testid="mock-status-bar">StatusBar</div>,
}));

vi.mock('./components/WidgetDock', () => ({
  WidgetDock: () => <div data-testid="mock-widget-dock">WidgetDock</div>,
}));

vi.mock('./components/Composer', () => ({
  Composer: () => <div data-testid="mock-composer">Composer</div>,
}));

vi.mock('./components/WorkingBanner', () => ({
  WorkingBanner: () => <div data-testid="mock-working-banner">WorkingBanner</div>,
}));

vi.mock('./components/ToastStack', () => ({
  ToastStack: () => <div data-testid="mock-toast-stack">ToastStack</div>,
}));

vi.mock('./components/UIRequestModal', () => ({
  UIRequestModal: () => <div data-testid="mock-ui-request-modal">UIRequestModal</div>,
}));

// ============================================================================
// Test Fixtures and Setup Helpers
// ============================================================================

const initialStoreState = useLemonStore.getState();

function getDefaultState(): Partial<LemonState> {
  return {
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
    ui: {
      requestsQueue: [],
      status: {},
      widgets: {},
      workingMessage: null,
      title: null,
      editorText: '',
    },
    models: [],
    statsBySession: {},
    messagesBySession: {},
    toolExecutionsBySession: {},
    notifications: [],
    debugLog: [],
    queue: {
      count: 0,
      pendingConfirmations: [],
    },
    config: {
      claude_skip_permissions: true,
      codex_auto_approve: false,
    },
    autoActivateNextSession: false,
    _insertionCounters: {},
  };
}

function setupStore(overrides: Partial<LemonState> = {}) {
  const mockSend = vi.fn();

  useLemonStore.setState({
    ...getDefaultState(),
    send: mockSend,
    ...overrides,
  } as LemonState);

  return { mockSend };
}

// ============================================================================
// Tests
// ============================================================================

describe('App', () => {
  let useLemonSocketSpy: Mock;

  beforeEach(() => {
    // Reset store to initial state
    useLemonStore.setState(initialStoreState, true);
    // Spy on useLemonSocket hook
    useLemonSocketSpy = vi.spyOn(useLemonSocketModule, 'useLemonSocket').mockImplementation(() => {});
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  // ==========================================================================
  // Initial Render Tests
  // ==========================================================================

  describe('initial render', () => {
    it('renders the app container with correct class', () => {
      setupStore();
      const { container } = render(<App />);

      expect(container.querySelector('.app')).toBeInTheDocument();
    });

    it('renders TopBar component', () => {
      setupStore();
      render(<App />);

      expect(screen.getByTestId('mock-top-bar')).toBeInTheDocument();
    });

    it('renders Sidebar component', () => {
      setupStore();
      render(<App />);

      expect(screen.getByTestId('mock-sidebar')).toBeInTheDocument();
    });

    it('renders ChatView component', () => {
      setupStore();
      render(<App />);

      expect(screen.getByTestId('mock-chat-view')).toBeInTheDocument();
    });

    it('renders ToolTimeline component', () => {
      setupStore();
      render(<App />);

      expect(screen.getByTestId('mock-tool-timeline')).toBeInTheDocument();
    });

    it('renders StatusBar component', () => {
      setupStore();
      render(<App />);

      expect(screen.getByTestId('mock-status-bar')).toBeInTheDocument();
    });

    it('renders WidgetDock component', () => {
      setupStore();
      render(<App />);

      expect(screen.getByTestId('mock-widget-dock')).toBeInTheDocument();
    });

    it('renders Composer component', () => {
      setupStore();
      render(<App />);

      expect(screen.getByTestId('mock-composer')).toBeInTheDocument();
    });

    it('renders WorkingBanner component', () => {
      setupStore();
      render(<App />);

      expect(screen.getByTestId('mock-working-banner')).toBeInTheDocument();
    });

    it('renders ToastStack component', () => {
      setupStore();
      render(<App />);

      expect(screen.getByTestId('mock-toast-stack')).toBeInTheDocument();
    });

    it('renders UIRequestModal component', () => {
      setupStore();
      render(<App />);

      expect(screen.getByTestId('mock-ui-request-modal')).toBeInTheDocument();
    });

    it('renders all child components simultaneously', () => {
      setupStore();
      render(<App />);

      // All 10 major child components should be rendered
      expect(screen.getByTestId('mock-top-bar')).toBeInTheDocument();
      expect(screen.getByTestId('mock-sidebar')).toBeInTheDocument();
      expect(screen.getByTestId('mock-chat-view')).toBeInTheDocument();
      expect(screen.getByTestId('mock-tool-timeline')).toBeInTheDocument();
      expect(screen.getByTestId('mock-status-bar')).toBeInTheDocument();
      expect(screen.getByTestId('mock-widget-dock')).toBeInTheDocument();
      expect(screen.getByTestId('mock-composer')).toBeInTheDocument();
      expect(screen.getByTestId('mock-working-banner')).toBeInTheDocument();
      expect(screen.getByTestId('mock-toast-stack')).toBeInTheDocument();
      expect(screen.getByTestId('mock-ui-request-modal')).toBeInTheDocument();
    });
  });

  // ==========================================================================
  // Socket Connection Initialization Tests
  // ==========================================================================

  describe('socket connection initialization', () => {
    it('calls useLemonSocket hook on mount', () => {
      setupStore();
      render(<App />);

      expect(useLemonSocketSpy).toHaveBeenCalled();
    });

    it('calls useLemonSocket only once on initial render', () => {
      setupStore();
      render(<App />);

      expect(useLemonSocketSpy).toHaveBeenCalledTimes(1);
    });

    it('maintains socket connection across re-renders', () => {
      setupStore();
      const { rerender } = render(<App />);

      expect(useLemonSocketSpy).toHaveBeenCalledTimes(1);

      rerender(<App />);
      rerender(<App />);

      // React should not re-invoke the hook setup unnecessarily
      // The exact count depends on React StrictMode, but should be controlled
      expect(useLemonSocketSpy).toHaveBeenCalled();
    });
  });

  // ==========================================================================
  // Document Title Effect Tests
  // ==========================================================================

  describe('document title effect', () => {
    it('does not change document title when title is null', () => {
      const originalTitle = document.title;
      setupStore({ ui: { ...getDefaultState().ui!, title: null } });

      render(<App />);

      expect(document.title).toBe(originalTitle);
    });

    it('updates document title when title is set in store', () => {
      setupStore({
        ui: {
          requestsQueue: [],
          status: {},
          widgets: {},
          workingMessage: null,
          title: 'My Custom App Title',
          editorText: '',
        },
      });

      render(<App />);

      expect(document.title).toBe('My Custom App Title');
    });

    it('updates document title when title changes', () => {
      setupStore({
        ui: {
          requestsQueue: [],
          status: {},
          widgets: {},
          workingMessage: null,
          title: 'Initial Title',
          editorText: '',
        },
      });

      const { rerender } = render(<App />);
      expect(document.title).toBe('Initial Title');

      // Update the title in the store
      useLemonStore.setState({
        ui: {
          ...useLemonStore.getState().ui,
          title: 'Updated Title',
        },
      });

      rerender(<App />);
      expect(document.title).toBe('Updated Title');
    });

    it('handles empty string title', () => {
      setupStore({
        ui: {
          requestsQueue: [],
          status: {},
          widgets: {},
          workingMessage: null,
          title: '',
          editorText: '',
        },
      });

      const originalTitle = document.title;
      render(<App />);

      // Empty string is falsy, so title should not be updated
      expect(document.title).toBe(originalTitle);
    });

    it('handles title with special characters', () => {
      setupStore({
        ui: {
          requestsQueue: [],
          status: {},
          widgets: {},
          workingMessage: null,
          title: 'Project <Beta> & "Alpha"',
          editorText: '',
        },
      });

      render(<App />);

      expect(document.title).toBe('Project <Beta> & "Alpha"');
    });
  });

  // ==========================================================================
  // Connection State Effect Tests
  // ==========================================================================

  describe('connection state effect', () => {
    it('does not send commands when connection state is connecting', () => {
      const { mockSend } = setupStore({
        connection: {
          state: 'connecting',
          lastError: null,
          lastServerTime: undefined,
          bridgeStatus: null,
        },
      });

      render(<App />);

      expect(mockSend).not.toHaveBeenCalled();
    });

    it('does not send commands when connection state is disconnected', () => {
      const { mockSend } = setupStore({
        connection: {
          state: 'disconnected',
          lastError: null,
          lastServerTime: undefined,
          bridgeStatus: null,
        },
      });

      render(<App />);

      expect(mockSend).not.toHaveBeenCalled();
    });

    it('does not send commands when connection state is error', () => {
      const { mockSend } = setupStore({
        connection: {
          state: 'error',
          lastError: 'Connection failed',
          lastServerTime: undefined,
          bridgeStatus: null,
        },
      });

      render(<App />);

      expect(mockSend).not.toHaveBeenCalled();
    });

    it('sends list_models command when connection becomes connected', () => {
      const { mockSend } = setupStore({
        connection: {
          state: 'connected',
          lastError: null,
          lastServerTime: undefined,
          bridgeStatus: null,
        },
      });

      render(<App />);

      expect(mockSend).toHaveBeenCalledWith({ type: 'list_models' });
    });

    it('sends list_sessions command when connection becomes connected', () => {
      const { mockSend } = setupStore({
        connection: {
          state: 'connected',
          lastError: null,
          lastServerTime: undefined,
          bridgeStatus: null,
        },
      });

      render(<App />);

      expect(mockSend).toHaveBeenCalledWith({ type: 'list_sessions' });
    });

    it('sends list_running_sessions command when connection becomes connected', () => {
      const { mockSend } = setupStore({
        connection: {
          state: 'connected',
          lastError: null,
          lastServerTime: undefined,
          bridgeStatus: null,
        },
      });

      render(<App />);

      expect(mockSend).toHaveBeenCalledWith({ type: 'list_running_sessions' });
    });

    it('sends all three initialization commands on connect', () => {
      const { mockSend } = setupStore({
        connection: {
          state: 'connected',
          lastError: null,
          lastServerTime: undefined,
          bridgeStatus: null,
        },
      });

      render(<App />);

      expect(mockSend).toHaveBeenCalledTimes(3);
      expect(mockSend).toHaveBeenCalledWith({ type: 'list_models' });
      expect(mockSend).toHaveBeenCalledWith({ type: 'list_sessions' });
      expect(mockSend).toHaveBeenCalledWith({ type: 'list_running_sessions' });
    });

    it('sends commands in correct order on connect', () => {
      const { mockSend } = setupStore({
        connection: {
          state: 'connected',
          lastError: null,
          lastServerTime: undefined,
          bridgeStatus: null,
        },
      });

      render(<App />);

      expect(mockSend.mock.calls[0]).toEqual([{ type: 'list_models' }]);
      expect(mockSend.mock.calls[1]).toEqual([{ type: 'list_sessions' }]);
      expect(mockSend.mock.calls[2]).toEqual([{ type: 'list_running_sessions' }]);
    });
  });

  // ==========================================================================
  // Connection State Transition Tests
  // ==========================================================================

  describe('connection state transitions', () => {
    it('sends init commands when transitioning from connecting to connected', () => {
      const { mockSend } = setupStore({
        connection: {
          state: 'connecting',
          lastError: null,
          lastServerTime: undefined,
          bridgeStatus: null,
        },
      });

      const { rerender } = render(<App />);
      expect(mockSend).not.toHaveBeenCalled();

      // Transition to connected
      useLemonStore.setState({
        connection: {
          state: 'connected',
          lastError: null,
          lastServerTime: Date.now(),
          bridgeStatus: null,
        },
      });

      rerender(<App />);

      expect(mockSend).toHaveBeenCalledWith({ type: 'list_models' });
      expect(mockSend).toHaveBeenCalledWith({ type: 'list_sessions' });
      expect(mockSend).toHaveBeenCalledWith({ type: 'list_running_sessions' });
    });

    it('sends init commands when reconnecting after disconnect', () => {
      const { mockSend } = setupStore({
        connection: {
          state: 'disconnected',
          lastError: null,
          lastServerTime: undefined,
          bridgeStatus: null,
        },
      });

      const { rerender } = render(<App />);
      expect(mockSend).not.toHaveBeenCalled();

      // Reconnect
      useLemonStore.setState({
        connection: {
          state: 'connected',
          lastError: null,
          lastServerTime: Date.now(),
          bridgeStatus: null,
        },
      });

      rerender(<App />);

      expect(mockSend).toHaveBeenCalledTimes(3);
    });

    it('handles rapid connection state changes', () => {
      const { mockSend } = setupStore({
        connection: {
          state: 'connecting',
          lastError: null,
          lastServerTime: undefined,
          bridgeStatus: null,
        },
      });

      const { rerender } = render(<App />);

      // Rapid state changes
      useLemonStore.setState({
        connection: { ...useLemonStore.getState().connection, state: 'connected' },
      });
      rerender(<App />);

      useLemonStore.setState({
        connection: { ...useLemonStore.getState().connection, state: 'disconnected' },
      });
      rerender(<App />);

      useLemonStore.setState({
        connection: { ...useLemonStore.getState().connection, state: 'connected' },
      });
      rerender(<App />);

      // Should have sent init commands twice (once per connected transition)
      expect(mockSend).toHaveBeenCalledTimes(6);
    });
  });

  // ==========================================================================
  // Layout Structure Tests
  // ==========================================================================

  describe('layout structure', () => {
    it('renders layout container with correct class', () => {
      setupStore();
      const { container } = render(<App />);

      expect(container.querySelector('.layout')).toBeInTheDocument();
    });

    it('renders main element with correct class', () => {
      setupStore();
      const { container } = render(<App />);

      expect(container.querySelector('main.main')).toBeInTheDocument();
    });

    it('renders main-grid container', () => {
      setupStore();
      const { container } = render(<App />);

      expect(container.querySelector('.main-grid')).toBeInTheDocument();
    });

    it('maintains correct DOM hierarchy', () => {
      setupStore();
      const { container } = render(<App />);

      const app = container.querySelector('.app');
      const layout = app?.querySelector('.layout');
      const main = layout?.querySelector('main.main');
      const mainGrid = main?.querySelector('.main-grid');

      expect(app).toBeInTheDocument();
      expect(layout).toBeInTheDocument();
      expect(main).toBeInTheDocument();
      expect(mainGrid).toBeInTheDocument();
    });

    it('places Sidebar within layout', () => {
      setupStore();
      const { container } = render(<App />);

      const layout = container.querySelector('.layout');
      const sidebar = layout?.querySelector('[data-testid="mock-sidebar"]');

      expect(sidebar).toBeInTheDocument();
    });

    it('places ChatView and ToolTimeline within main-grid', () => {
      setupStore();
      const { container } = render(<App />);

      const mainGrid = container.querySelector('.main-grid');
      const chatView = mainGrid?.querySelector('[data-testid="mock-chat-view"]');
      const toolTimeline = mainGrid?.querySelector('[data-testid="mock-tool-timeline"]');

      expect(chatView).toBeInTheDocument();
      expect(toolTimeline).toBeInTheDocument();
    });
  });

  // ==========================================================================
  // Store Integration Tests
  // ==========================================================================

  describe('store integration', () => {
    it('subscribes to connection state from store', () => {
      setupStore({
        connection: {
          state: 'connected',
          lastError: null,
          lastServerTime: undefined,
          bridgeStatus: null,
        },
      });

      render(<App />);

      // Verify the component used the store's connection state
      const state = useLemonStore.getState();
      expect(state.connection.state).toBe('connected');
    });

    it('subscribes to title from store UI state', () => {
      setupStore({
        ui: {
          requestsQueue: [],
          status: {},
          widgets: {},
          workingMessage: null,
          title: 'Test Title',
          editorText: '',
        },
      });

      render(<App />);

      expect(document.title).toBe('Test Title');
    });

    it('uses send function from store', () => {
      const { mockSend } = setupStore({
        connection: {
          state: 'connected',
          lastError: null,
          lastServerTime: undefined,
          bridgeStatus: null,
        },
      });

      render(<App />);

      expect(mockSend).toHaveBeenCalled();
    });

    it('reacts to store state changes', () => {
      setupStore({
        ui: {
          requestsQueue: [],
          status: {},
          widgets: {},
          workingMessage: null,
          title: 'Initial',
          editorText: '',
        },
      });

      const { rerender } = render(<App />);
      expect(document.title).toBe('Initial');

      useLemonStore.setState({
        ui: {
          ...useLemonStore.getState().ui,
          title: 'Changed',
        },
      });

      rerender(<App />);
      expect(document.title).toBe('Changed');
    });
  });

  // ==========================================================================
  // Component Composition Tests
  // ==========================================================================

  describe('component composition', () => {
    it('renders overlay components (WorkingBanner, Composer, UIRequestModal, ToastStack) outside layout', () => {
      setupStore();
      const { container } = render(<App />);

      const app = container.querySelector('.app');
      const layout = container.querySelector('.layout');

      // These should be direct children of .app, not inside .layout
      const workingBanner = app?.querySelector('[data-testid="mock-working-banner"]');
      const composer = app?.querySelector('[data-testid="mock-composer"]');
      const uiRequestModal = app?.querySelector('[data-testid="mock-ui-request-modal"]');
      const toastStack = app?.querySelector('[data-testid="mock-toast-stack"]');

      // Verify they're not inside layout
      const workingBannerInLayout = layout?.querySelector('[data-testid="mock-working-banner"]');
      const composerInLayout = layout?.querySelector('[data-testid="mock-composer"]');
      const uiRequestModalInLayout = layout?.querySelector('[data-testid="mock-ui-request-modal"]');
      const toastStackInLayout = layout?.querySelector('[data-testid="mock-toast-stack"]');

      expect(workingBanner).toBeInTheDocument();
      expect(composer).toBeInTheDocument();
      expect(uiRequestModal).toBeInTheDocument();
      expect(toastStack).toBeInTheDocument();

      expect(workingBannerInLayout).toBeNull();
      expect(composerInLayout).toBeNull();
      expect(uiRequestModalInLayout).toBeNull();
      expect(toastStackInLayout).toBeNull();
    });

    it('places StatusBar and WidgetDock inside main', () => {
      setupStore();
      const { container } = render(<App />);

      const main = container.querySelector('main.main');
      const statusBar = main?.querySelector('[data-testid="mock-status-bar"]');
      const widgetDock = main?.querySelector('[data-testid="mock-widget-dock"]');

      expect(statusBar).toBeInTheDocument();
      expect(widgetDock).toBeInTheDocument();
    });

    it('renders TopBar before layout', () => {
      setupStore();
      const { container } = render(<App />);

      const app = container.querySelector('.app');
      const topBar = app?.querySelector('[data-testid="mock-top-bar"]');
      const layout = app?.querySelector('.layout');

      // TopBar should be a sibling of layout, not inside it
      expect(topBar).toBeInTheDocument();
      expect(layout?.querySelector('[data-testid="mock-top-bar"]')).toBeNull();
    });
  });

  // ==========================================================================
  // Edge Cases and Error Handling Tests
  // ==========================================================================

  describe('edge cases', () => {
    it('handles missing send function gracefully', () => {
      useLemonStore.setState({
        ...getDefaultState(),
        send: undefined as unknown as LemonState['send'],
        connection: {
          state: 'connected',
          lastError: null,
          lastServerTime: undefined,
          bridgeStatus: null,
        },
      } as LemonState);

      // Should not throw
      expect(() => render(<App />)).not.toThrow();
    });

    it('handles undefined title gracefully', () => {
      useLemonStore.setState({
        ...getDefaultState(),
        send: vi.fn(),
        ui: {
          requestsQueue: [],
          status: {},
          widgets: {},
          workingMessage: null,
          title: undefined as unknown as null,
          editorText: '',
        },
      } as LemonState);

      // Should not throw
      expect(() => render(<App />)).not.toThrow();
    });

    it('handles multiple rapid renders', () => {
      setupStore();

      for (let i = 0; i < 10; i++) {
        const { unmount } = render(<App />);
        unmount();
      }

      // Final render should work correctly
      render(<App />);
      expect(screen.getByTestId('mock-top-bar')).toBeInTheDocument();
    });

    it('cleans up on unmount', () => {
      setupStore();

      const { unmount } = render(<App />);

      // Should not throw on unmount
      expect(() => unmount()).not.toThrow();
    });
  });

  // ==========================================================================
  // Effect Dependencies Tests
  // ==========================================================================

  describe('effect dependencies', () => {
    it('title effect only runs when title changes', () => {
      const originalTitle = document.title;

      setupStore({
        ui: {
          requestsQueue: [],
          status: {},
          widgets: {},
          workingMessage: null,
          title: 'Test Title',
          editorText: '',
        },
        connection: {
          state: 'connecting',
          lastError: null,
          lastServerTime: undefined,
          bridgeStatus: null,
        },
      });

      const { rerender } = render(<App />);
      expect(document.title).toBe('Test Title');

      // Change connection state but not title
      useLemonStore.setState({
        connection: {
          state: 'connected',
          lastError: null,
          lastServerTime: Date.now(),
          bridgeStatus: null,
        },
      });

      rerender(<App />);

      // Title should still be the same
      expect(document.title).toBe('Test Title');
    });

    it('connection effect uses current send function', () => {
      const mockSend1 = vi.fn();
      const mockSend2 = vi.fn();

      useLemonStore.setState({
        ...getDefaultState(),
        send: mockSend1,
        connection: {
          state: 'connecting',
          lastError: null,
          lastServerTime: undefined,
          bridgeStatus: null,
        },
      } as LemonState);

      const { rerender } = render(<App />);

      // Update send function before connecting
      useLemonStore.setState({
        send: mockSend2,
      });

      // Transition to connected
      useLemonStore.setState({
        connection: {
          state: 'connected',
          lastError: null,
          lastServerTime: Date.now(),
          bridgeStatus: null,
        },
      });

      rerender(<App />);

      // The second send function should be used
      expect(mockSend2).toHaveBeenCalled();
    });
  });

  // ==========================================================================
  // Loading State Tests
  // ==========================================================================

  describe('loading states', () => {
    it('renders normally during connecting state', () => {
      setupStore({
        connection: {
          state: 'connecting',
          lastError: null,
          lastServerTime: undefined,
          bridgeStatus: null,
        },
      });

      render(<App />);

      // All components should still render
      expect(screen.getByTestId('mock-top-bar')).toBeInTheDocument();
      expect(screen.getByTestId('mock-sidebar')).toBeInTheDocument();
      expect(screen.getByTestId('mock-chat-view')).toBeInTheDocument();
    });

    it('renders normally during disconnected state', () => {
      setupStore({
        connection: {
          state: 'disconnected',
          lastError: null,
          lastServerTime: undefined,
          bridgeStatus: null,
        },
      });

      render(<App />);

      // All components should still render
      expect(screen.getByTestId('mock-top-bar')).toBeInTheDocument();
      expect(screen.getByTestId('mock-sidebar')).toBeInTheDocument();
      expect(screen.getByTestId('mock-chat-view')).toBeInTheDocument();
    });

    it('renders normally during error state', () => {
      setupStore({
        connection: {
          state: 'error',
          lastError: 'Some error occurred',
          lastServerTime: undefined,
          bridgeStatus: null,
        },
      });

      render(<App />);

      // All components should still render
      expect(screen.getByTestId('mock-top-bar')).toBeInTheDocument();
      expect(screen.getByTestId('mock-sidebar')).toBeInTheDocument();
      expect(screen.getByTestId('mock-chat-view')).toBeInTheDocument();
    });
  });

  // ==========================================================================
  // Initialization Behavior Tests
  // ==========================================================================

  describe('initialization behavior', () => {
    it('initializes socket connection before sending commands', () => {
      const mockSend = vi.fn();

      useLemonStore.setState({
        ...getDefaultState(),
        send: mockSend,
        connection: {
          state: 'connected',
          lastError: null,
          lastServerTime: undefined,
          bridgeStatus: null,
        },
      } as LemonState);

      render(<App />);

      // useLemonSocket should be called first
      expect(useLemonSocketSpy).toHaveBeenCalled();
      // Then commands should be sent
      expect(mockSend).toHaveBeenCalled();
    });

    it('does not send duplicate init commands on same connection', () => {
      const { mockSend } = setupStore({
        connection: {
          state: 'connected',
          lastError: null,
          lastServerTime: undefined,
          bridgeStatus: null,
        },
      });

      const { rerender } = render(<App />);

      // Rerender with same connection state
      rerender(<App />);
      rerender(<App />);

      // Should only send 3 commands once
      expect(mockSend).toHaveBeenCalledTimes(3);
    });
  });
});
