import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen } from '@testing-library/react';
import { MonitoringApp } from './MonitoringApp';
import { useMonitoringStore, INITIAL_INSTANCE, INITIAL_UI } from '../../store/monitoringStore';

// Mock useControlPlane to avoid real WebSocket connections
vi.mock('../../rpc/useControlPlane', () => ({
  useControlPlane: vi.fn().mockReturnValue({
    connectionState: 'disconnected' as const,
    isConnected: false,
    snapshot: null,
    lastEvent: null,
    request: vi.fn().mockRejectedValue(new Error('Not connected')),
    connect: vi.fn(),
    disconnect: vi.fn(),
  }),
}));

function resetStore() {
  useMonitoringStore.setState({
    instance: { ...INITIAL_INSTANCE },
    agents: {},
    sessions: {
      active: {},
      historical: [],
      selectedSessionKey: null,
      loadedSessionKeys: new Set(),
    },
    runs: { active: {}, recent: [] },
    tasks: { active: {}, recent: [] },
    eventFeed: [],
    ui: { ...INITIAL_UI, filters: { ...INITIAL_UI.filters, eventTypes: [] } },
  });
}

describe('MonitoringApp', () => {
  beforeEach(() => resetStore());
  afterEach(() => resetStore());

  it('renders the monitoring app container', () => {
    render(<MonitoringApp />);
    expect(screen.getByTestId('monitoring-app')).toBeInTheDocument();
  });

  it('renders the status strip', () => {
    render(<MonitoringApp />);
    expect(screen.getByTestId('status-strip')).toBeInTheDocument();
    expect(screen.getByText('LEMON MONITOR')).toBeInTheDocument();
  });

  it('renders the agent sessions sidebar', () => {
    render(<MonitoringApp />);
    expect(screen.getByTestId('agent-sessions-sidebar')).toBeInTheDocument();
  });

  it('renders the overview panel by default', () => {
    render(<MonitoringApp />);
    expect(screen.getByTestId('overview-panel')).toBeInTheDocument();
    // "Overview" appears in both the nav bar and the panel heading
    expect(screen.getAllByText('Overview').length).toBeGreaterThanOrEqual(1);
  });

  it('renders navigation buttons for all screens', () => {
    render(<MonitoringApp />);
    // Nav bar buttons
    expect(screen.getAllByText('Sessions').length).toBeGreaterThanOrEqual(1);
    expect(screen.getAllByText('Events').length).toBeGreaterThanOrEqual(1);
    expect(screen.getAllByText('Tasks').length).toBeGreaterThanOrEqual(1);
  });

  it('renders collapsed event feed in sidebar when not on events screen', () => {
    render(<MonitoringApp />);
    expect(screen.getByTestId('event-feed-collapsed')).toBeInTheDocument();
  });

  it('shows health card in overview', () => {
    useMonitoringStore.setState({
      instance: { ...INITIAL_INSTANCE, status: 'healthy' },
    });
    render(<MonitoringApp />);
    expect(screen.getByText('Health')).toBeInTheDocument();
  });

  it('shows activity card in overview', () => {
    useMonitoringStore.setState({
      instance: { ...INITIAL_INSTANCE, activeRuns: 3 },
    });
    render(<MonitoringApp />);
    expect(screen.getByText('Activity')).toBeInTheDocument();
  });

  it('renders without crashing with completely empty state', () => {
    render(<MonitoringApp />);
    expect(screen.getByTestId('monitoring-app')).toBeInTheDocument();
    expect(screen.getByText('LEMON MONITOR')).toBeInTheDocument();
  });
});
