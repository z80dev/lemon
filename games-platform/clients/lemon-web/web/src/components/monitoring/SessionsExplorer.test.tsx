import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { SessionsExplorer } from './SessionsExplorer';
import { useMonitoringStore, INITIAL_INSTANCE, INITIAL_UI } from '../../store/monitoringStore';
import type { MonitoringSession } from '../../../../shared/src/monitoringTypes';

function makeSession(overrides: Partial<MonitoringSession> = {}): MonitoringSession {
  return {
    sessionKey: 'session-1',
    agentId: 'agent-a',
    kind: 'chat',
    channelId: 'telegram',
    accountId: null,
    peerId: 'user-123',
    peerLabel: 'Test User',
    active: true,
    runId: null,
    runCount: 2,
    createdAtMs: Date.now() - 60_000,
    updatedAtMs: Date.now() - 10_000,
    route: {},
    origin: null,
    ...overrides,
  };
}

function resetStore() {
  useMonitoringStore.setState({
    instance: { ...INITIAL_INSTANCE },
    sessions: {
      active: {},
      historical: [],
      selectedSessionKey: null,
      loadedSessionKeys: new Set(),
    },
    ui: { ...INITIAL_UI, filters: { ...INITIAL_UI.filters, eventTypes: [] } },
  });
}

describe('SessionsExplorer', () => {
  beforeEach(() => resetStore());
  afterEach(() => resetStore());

  it('renders with empty state', () => {
    render(<SessionsExplorer />);
    expect(screen.getByTestId('sessions-explorer')).toBeInTheDocument();
    expect(screen.getByText('No sessions found')).toBeInTheDocument();
  });

  it('renders sessions table with mock data', () => {
    const s1 = makeSession({ sessionKey: 'sess-abc' });
    const s2 = makeSession({ sessionKey: 'sess-xyz', agentId: 'agent-b', active: false });
    useMonitoringStore.setState({
      sessions: {
        active: { 'sess-abc': s1, 'sess-xyz': s2 },
        historical: [],
        selectedSessionKey: null,
        loadedSessionKeys: new Set(),
      },
    });
    render(<SessionsExplorer />);
    expect(screen.getByTestId('sessions-table')).toBeInTheDocument();
    expect(screen.getByText('2 results')).toBeInTheDocument();
  });

  it('renders table headers', () => {
    render(<SessionsExplorer />);
    expect(screen.getByText('SessionKey')).toBeInTheDocument();
    expect(screen.getByText('Agent')).toBeInTheDocument();
    expect(screen.getByText('Channel')).toBeInTheDocument();
    expect(screen.getByText('Peer')).toBeInTheDocument();
    expect(screen.getByText('Runs')).toBeInTheDocument();
    expect(screen.getByText('Last Active')).toBeInTheDocument();
  });

  it('search filter narrows results', () => {
    const s1 = makeSession({ sessionKey: 'alpha-session' });
    const s2 = makeSession({ sessionKey: 'beta-session', agentId: 'agent-b' });
    useMonitoringStore.setState({
      sessions: {
        active: { 'alpha-session': s1, 'beta-session': s2 },
        historical: [],
        selectedSessionKey: null,
        loadedSessionKeys: new Set(),
      },
    });
    render(<SessionsExplorer />);

    const searchInput = screen.getByTestId('session-search');
    fireEvent.change(searchInput, { target: { value: 'alpha' } });

    expect(screen.getByText('1 result')).toBeInTheDocument();
  });

  it('clicking row calls setSelectedSession in store', () => {
    const s1 = makeSession({ sessionKey: 'sess-click' });
    useMonitoringStore.setState({
      sessions: {
        active: { 'sess-click': s1 },
        historical: [],
        selectedSessionKey: null,
        loadedSessionKeys: new Set(),
      },
    });
    render(<SessionsExplorer />);

    const row = screen.getByTestId('session-row-sess-click');
    fireEvent.click(row);

    const state = useMonitoringStore.getState();
    expect(state.ui.selectedSessionKey).toBe('sess-click');
  });

  it('shows sessions with correct agent and channel values', () => {
    const s1 = makeSession({ sessionKey: 'sess-details', agentId: 'special-agent', channelId: 'slack' });
    useMonitoringStore.setState({
      sessions: {
        active: { 'sess-details': s1 },
        historical: [],
        selectedSessionKey: null,
        loadedSessionKeys: new Set(),
      },
    });
    render(<SessionsExplorer />);

    expect(screen.getByText('special-agent')).toBeInTheDocument();
    expect(screen.getByText('slack')).toBeInTheDocument();
  });

  it('search by peerId works', () => {
    const s1 = makeSession({ sessionKey: 'sess-p1', peerId: 'unique-peer-id' });
    const s2 = makeSession({ sessionKey: 'sess-p2', peerId: 'other-peer' });
    useMonitoringStore.setState({
      sessions: {
        active: { 'sess-p1': s1, 'sess-p2': s2 },
        historical: [],
        selectedSessionKey: null,
        loadedSessionKeys: new Set(),
      },
    });
    render(<SessionsExplorer />);

    const searchInput = screen.getByTestId('session-search');
    fireEvent.change(searchInput, { target: { value: 'unique-peer' } });

    expect(screen.getByText('1 result')).toBeInTheDocument();
  });

  it('displays run count in table', () => {
    const s1 = makeSession({ sessionKey: 'sess-runs', runCount: 5 });
    useMonitoringStore.setState({
      sessions: {
        active: { 'sess-runs': s1 },
        historical: [],
        selectedSessionKey: null,
        loadedSessionKeys: new Set(),
      },
    });
    render(<SessionsExplorer />);

    expect(screen.getByText('5')).toBeInTheDocument();
  });
});
