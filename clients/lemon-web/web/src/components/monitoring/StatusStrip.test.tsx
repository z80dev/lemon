import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { render, screen } from '@testing-library/react';
import { StatusStrip } from './StatusStrip';
import { useMonitoringStore, INITIAL_INSTANCE } from '../../store/monitoringStore';

function resetStore() {
  useMonitoringStore.setState({
    instance: { ...INITIAL_INSTANCE },
  });
}

function setupStore(overrides: Partial<typeof INITIAL_INSTANCE> = {}) {
  useMonitoringStore.setState({
    instance: { ...INITIAL_INSTANCE, ...overrides },
  });
}

describe('StatusStrip', () => {
  beforeEach(() => resetStore());
  afterEach(() => resetStore());

  it('renders the LEMON MONITOR title', () => {
    setupStore();
    render(<StatusStrip connectionState="connected" />);
    expect(screen.getByText('LEMON MONITOR')).toBeInTheDocument();
  });

  it('shows green connection dot when connected', () => {
    setupStore();
    render(<StatusStrip connectionState="connected" />);
    const dot = screen.getByTestId('connection-dot');
    expect(dot.style.background).toBe('rgb(0, 255, 136)');
  });

  it('shows red connection dot when disconnected', () => {
    setupStore();
    render(<StatusStrip connectionState="disconnected" />);
    const dot = screen.getByTestId('connection-dot');
    expect(dot.style.background).toBe('rgb(255, 68, 68)');
  });

  it('shows red connection dot when error', () => {
    setupStore();
    render(<StatusStrip connectionState="error" />);
    const dot = screen.getByTestId('connection-dot');
    expect(dot.style.background).toBe('rgb(255, 68, 68)');
  });

  it('shows yellow connection dot when reconnecting', () => {
    setupStore();
    render(<StatusStrip connectionState="reconnecting" />);
    const dot = screen.getByTestId('connection-dot');
    expect(dot.style.background).toBe('rgb(255, 170, 0)');
  });

  it('shows uptime from store', () => {
    setupStore({ uptimeMs: 3_660_000 }); // 1h 1m
    render(<StatusStrip connectionState="connected" />);
    expect(screen.getByTestId('uptime-value').textContent).toBe('1h 1m');
  });

  it('shows -- when uptime is null', () => {
    setupStore({ uptimeMs: null });
    render(<StatusStrip connectionState="connected" />);
    expect(screen.getByTestId('uptime-value').textContent).toBe('--');
  });

  it('shows active run count', () => {
    setupStore({ activeRuns: 3 });
    render(<StatusStrip connectionState="connected" />);
    expect(screen.getByTestId('active-runs').textContent).toBe('3');
  });

  it('shows queued run count', () => {
    setupStore({ queuedRuns: 7 });
    render(<StatusStrip connectionState="connected" />);
    expect(screen.getByTestId('queued-runs').textContent).toBe('7');
  });

  it('shows connected clients count', () => {
    setupStore({ connectedClients: 5 });
    render(<StatusStrip connectionState="connected" />);
    expect(screen.getByTestId('clients-count').textContent).toBe('5');
  });

  it('shows health badge from store', () => {
    setupStore({ status: 'healthy' });
    render(<StatusStrip connectionState="connected" />);
    expect(screen.getByTestId('health-badge').textContent).toBe('healthy');
  });

  it('renders health badge as degraded when status is degraded', () => {
    setupStore({ status: 'degraded' });
    render(<StatusStrip connectionState="connected" />);
    expect(screen.getByTestId('health-badge').textContent).toBe('degraded');
  });

  it('renders without crashing with empty initial state', () => {
    render(<StatusStrip connectionState="disconnected" />);
    expect(screen.getByTestId('status-strip')).toBeInTheDocument();
  });
});
