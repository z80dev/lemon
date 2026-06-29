import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import { MonitoringApp } from './MonitoringApp';
import { useMonitoringStore, INITIAL_INSTANCE, INITIAL_UI } from '../../store/monitoringStore';
import { useControlPlane } from '../../rpc/useControlPlane';

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
    sessionDetails: {},
    runs: { active: {}, recent: [] },
    tasks: { active: {}, recent: [] },
    cron: { status: null, jobs: [], runsByJob: {}, selectedJobId: null },
    system: { channels: [], transports: [], skills: { installed: 0, enabled: 0 } },
    runIntrospection: {},
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

  it('does not render the collapsed event feed rail', () => {
    render(<MonitoringApp />);
    expect(screen.queryByTestId('event-feed-collapsed')).not.toBeInTheDocument();
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

  it('surfaces partial monitoring load failures', async () => {
    const request = vi.fn((method: string) => {
      if (method === 'sessions.list') {
        return Promise.reject(new Error('backend down'));
      }
      return Promise.resolve({});
    });

    vi.mocked(useControlPlane).mockReturnValue({
      connectionState: 'connected',
      isConnected: true,
      snapshot: null,
      lastEvent: null,
      request,
      connect: vi.fn(),
      disconnect: vi.fn(),
    });

    render(<MonitoringApp />);

    await waitFor(() => {
      expect(screen.getByRole('alert')).toHaveTextContent(
        'Monitoring data partially failed to load: sessions.list'
      );
    });
  });

  it('shows session detail load failure without caching an empty detail', async () => {
    const request = vi.fn((method: string) => {
      if (method === 'session.detail') {
        return Promise.reject(new Error('detail unavailable'));
      }
      return Promise.resolve({});
    });

    vi.mocked(useControlPlane).mockReturnValue({
      connectionState: 'connected',
      isConnected: true,
      snapshot: null,
      lastEvent: null,
      request,
      connect: vi.fn(),
      disconnect: vi.fn(),
    });

    useMonitoringStore.setState({
      sessions: {
        active: {},
        historical: [
          {
            sessionKey: 'agent:test:session',
            agentId: 'test',
            status: 'idle',
            active: true,
            createdAtMs: Date.now(),
            updatedAtMs: Date.now(),
          },
        ],
        selectedSessionKey: 'agent:test:session',
        loadedSessionKeys: new Set(),
      },
    });

    render(<MonitoringApp />);
    screen.getAllByRole('button', { name: 'Sessions' })[0].click();
    screen.getByTestId('session-item-agent:test:session').click();

    await waitFor(() => {
      expect(screen.getByText('Failed to load session detail: detail unavailable')).toBeInTheDocument();
    });

    expect(screen.queryByText('No run history available.')).not.toBeInTheDocument();
    expect(useMonitoringStore.getState().sessionDetails['agent:test:session']).toBeUndefined();
  });
});
