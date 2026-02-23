import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { render, screen } from '@testing-library/react';
import { RunInspector } from './RunInspector';
import { useMonitoringStore, INITIAL_INSTANCE, INITIAL_UI } from '../../store/monitoringStore';
import type { MonitoringRun, FeedEvent } from '../../../../shared/src/monitoringTypes';

function makeRun(overrides: Partial<MonitoringRun> = {}): MonitoringRun {
  return {
    runId: 'run-123',
    sessionKey: 'sess-abc',
    agentId: 'agent-1',
    engine: 'claude',
    startedAtMs: Date.now() - 30_000,
    completedAtMs: null,
    durationMs: 30_000,
    status: 'active',
    ok: null,
    parentRunId: null,
    ...overrides,
  };
}

function makeFeedEvent(overrides: Partial<FeedEvent> = {}): FeedEvent {
  return {
    id: 'feed-1',
    eventName: 'agent',
    payload: { type: 'started', run_id: 'run-123' },
    seq: 1,
    receivedAtMs: Date.now(),
    runId: 'run-123',
    level: 'info',
    ...overrides,
  };
}

function resetStore() {
  useMonitoringStore.setState({
    instance: { ...INITIAL_INSTANCE },
    runs: { active: {}, recent: [] },
    tasks: { active: {}, recent: [] },
    eventFeed: [],
    ui: { ...INITIAL_UI, filters: { ...INITIAL_UI.filters, eventTypes: [] } },
  });
}

describe('RunInspector', () => {
  beforeEach(() => resetStore());
  afterEach(() => resetStore());

  it('shows placeholder when no run selected', () => {
    render(<RunInspector />);
    expect(screen.getByTestId('run-inspector')).toBeInTheDocument();
    expect(screen.getByText('Select a run to inspect')).toBeInTheDocument();
  });

  it('shows run ID when run selected', () => {
    const run = makeRun({ runId: 'run-visible-id' });
    useMonitoringStore.setState({
      runs: { active: { 'run-visible-id': run }, recent: [] },
      ui: { ...INITIAL_UI, selectedRunId: 'run-visible-id', filters: { ...INITIAL_UI.filters, eventTypes: [] } },
    });
    render(<RunInspector />);
    expect(screen.getByTestId('run-id').textContent).toBe('run-visible-id');
  });

  it('shows run status badge', () => {
    const run = makeRun({ runId: 'run-stat', status: 'error' });
    useMonitoringStore.setState({
      runs: { active: { 'run-stat': run }, recent: [] },
      ui: { ...INITIAL_UI, selectedRunId: 'run-stat', filters: { ...INITIAL_UI.filters, eventTypes: [] } },
    });
    render(<RunInspector />);
    expect(screen.getByTestId('run-status-badge').textContent).toBe('error');
  });

  it('tool timeline renders correctly when events exist', () => {
    const run = makeRun({ runId: 'run-tools' });
    const toolEvent = makeFeedEvent({
      id: 'tool-ev-1',
      eventName: 'agent',
      runId: 'run-tools',
      payload: { type: 'tool_use', tool_name: 'read_file', status: 'complete', run_id: 'run-tools' },
    });
    useMonitoringStore.setState({
      runs: { active: { 'run-tools': run }, recent: [] },
      eventFeed: [toolEvent],
      ui: { ...INITIAL_UI, selectedRunId: 'run-tools', filters: { ...INITIAL_UI.filters, eventTypes: [] } },
    });
    render(<RunInspector />);
    expect(screen.getByTestId('tool-item-0')).toBeInTheDocument();
    expect(screen.getByText('read_file')).toBeInTheDocument();
  });

  it('shows placeholder text when no run found in recent or active', () => {
    useMonitoringStore.setState({
      runs: { active: {}, recent: [] },
      ui: { ...INITIAL_UI, selectedRunId: 'nonexistent', filters: { ...INITIAL_UI.filters, eventTypes: [] } },
    });
    render(<RunInspector />);
    expect(screen.getByText('Select a run to inspect')).toBeInTheDocument();
  });

  it('finds run in recent list when not in active', () => {
    const run = makeRun({ runId: 'run-recent', status: 'completed' });
    useMonitoringStore.setState({
      runs: { active: {}, recent: [run] },
      ui: { ...INITIAL_UI, selectedRunId: 'run-recent', filters: { ...INITIAL_UI.filters, eventTypes: [] } },
    });
    render(<RunInspector />);
    expect(screen.getByTestId('run-id').textContent).toBe('run-recent');
  });
});
