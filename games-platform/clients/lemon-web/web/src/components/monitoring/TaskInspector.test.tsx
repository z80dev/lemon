import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { render, screen } from '@testing-library/react';
import { TaskInspector } from './TaskInspector';
import { useMonitoringStore, INITIAL_INSTANCE, INITIAL_UI } from '../../store/monitoringStore';
import type { MonitoringTask } from '../../../../shared/src/monitoringTypes';

function makeTask(overrides: Partial<MonitoringTask> = {}): MonitoringTask {
  return {
    taskId: 'task-1',
    parentRunId: 'run-root',
    runId: 'run-root',
    sessionKey: 'sess-abc',
    agentId: 'agent-1',
    startedAtMs: Date.now() - 10_000,
    completedAtMs: null,
    durationMs: null,
    status: 'active',
    ...overrides,
  };
}

function resetStore() {
  useMonitoringStore.setState({
    instance: { ...INITIAL_INSTANCE },
    tasks: { active: {}, recent: [] },
    ui: { ...INITIAL_UI, filters: { ...INITIAL_UI.filters, eventTypes: [] } },
  });
}

describe('TaskInspector', () => {
  beforeEach(() => resetStore());
  afterEach(() => resetStore());

  it('shows placeholder when no run selected', () => {
    render(<TaskInspector />);
    expect(screen.getByTestId('task-inspector')).toBeInTheDocument();
    expect(screen.getByText('Select a run to view its task tree')).toBeInTheDocument();
  });

  it('renders task tree when run and tasks exist', () => {
    const task1 = makeTask({ taskId: 'task-alpha', parentRunId: 'run-root', status: 'completed' });
    const task2 = makeTask({ taskId: 'task-beta', parentRunId: 'run-root', status: 'active' });
    useMonitoringStore.setState({
      tasks: {
        active: { 'task-beta': task2 },
        recent: [task1],
      },
      ui: {
        ...INITIAL_UI,
        selectedRunId: 'run-root',
        filters: { ...INITIAL_UI.filters, eventTypes: [] },
      },
    });
    render(<TaskInspector />);
    expect(screen.getByTestId('task-node-task-alpha')).toBeInTheDocument();
    expect(screen.getByTestId('task-node-task-beta')).toBeInTheDocument();
  });

  it('shows no tasks message when run selected but no matching tasks', () => {
    useMonitoringStore.setState({
      tasks: { active: {}, recent: [] },
      ui: {
        ...INITIAL_UI,
        selectedRunId: 'run-empty',
        filters: { ...INITIAL_UI.filters, eventTypes: [] },
      },
    });
    render(<TaskInspector />);
    expect(screen.getByText('No tasks for this run')).toBeInTheDocument();
  });

  it('renders task status badges', () => {
    const task = makeTask({ taskId: 'task-err', parentRunId: 'run-root', status: 'error' });
    useMonitoringStore.setState({
      tasks: { active: { 'task-err': task }, recent: [] },
      ui: {
        ...INITIAL_UI,
        selectedRunId: 'run-root',
        filters: { ...INITIAL_UI.filters, eventTypes: [] },
      },
    });
    render(<TaskInspector />);
    expect(screen.getByText('error')).toBeInTheDocument();
  });

  it('displays Task Tree heading with run id', () => {
    const task = makeTask({ taskId: 'task-head', parentRunId: 'run-display' });
    useMonitoringStore.setState({
      tasks: { active: { 'task-head': task }, recent: [] },
      ui: {
        ...INITIAL_UI,
        selectedRunId: 'run-display',
        filters: { ...INITIAL_UI.filters, eventTypes: [] },
      },
    });
    render(<TaskInspector />);
    expect(screen.getByText('Task Tree')).toBeInTheDocument();
    expect(screen.getByText(/run-display/)).toBeInTheDocument();
  });
});
