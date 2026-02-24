import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { RunnersInspector } from './RunnersInspector';
import { useMonitoringStore, INITIAL_INSTANCE, INITIAL_UI } from '../../store/monitoringStore';
import type { MonitoringRun } from '../../../../shared/src/monitoringTypes';

function makeRun(overrides: Partial<MonitoringRun> = {}): MonitoringRun {
  return {
    runId: 'run-1',
    sessionKey: 'sess-1',
    agentId: 'agent-1',
    engine: 'codex',
    startedAtMs: Date.now() - 30_000,
    completedAtMs: null,
    durationMs: 30_000,
    status: 'active',
    ok: null,
    parentRunId: null,
    ...overrides,
  };
}

function resetStore() {
  useMonitoringStore.setState({
    instance: { ...INITIAL_INSTANCE },
    runs: { active: {}, recent: [] },
    tasks: { active: {}, recent: [] },
    eventFeed: [],
    runIntrospection: {},
    ui: { ...INITIAL_UI, filters: { ...INITIAL_UI.filters, eventTypes: [] } },
  });
}

describe('RunnersInspector', () => {
  beforeEach(() => resetStore());
  afterEach(() => resetStore());

  it('shows empty state when there are no runs', () => {
    render(<RunnersInspector />);
    expect(screen.getByTestId('runners-inspector')).toBeInTheDocument();
    expect(screen.getByText('No runner data yet')).toBeInTheDocument();
  });

  it('renders run rows and expands timeline section', () => {
    useMonitoringStore.setState({
      runs: {
        active: { 'run-abc': makeRun({ runId: 'run-abc', engine: 'claude' }) },
        recent: [makeRun({ runId: 'run-def', status: 'completed', engine: 'codex' })],
      },
      eventFeed: [
        {
          id: 'ev-1',
          eventName: 'agent',
          payload: { type: 'started', run_id: 'run-abc' },
          seq: 1,
          receivedAtMs: Date.now() - 20_000,
          runId: 'run-abc',
          level: 'info',
        },
      ],
    });

    render(<RunnersInspector request={vi.fn().mockResolvedValue({ events: [] })} />);
    expect(screen.getByText('run-abc')).toBeInTheDocument();
    fireEvent.click(screen.getByText('run-abc'));
    expect(screen.getByText(/(Reload Timeline|Loading…)/)).toBeInTheDocument();
  });
});
