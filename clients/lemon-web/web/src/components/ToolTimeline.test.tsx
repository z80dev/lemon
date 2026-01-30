import { cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it } from 'vitest';
import { ToolTimeline } from './ToolTimeline';
import { useLemonStore } from '../store/useLemonStore';

const initialState = useLemonStore.getState();

afterEach(() => {
  useLemonStore.setState(initialState, true);
  cleanup();
});

describe('ToolTimeline', () => {
  it('filters tool executions by status', async () => {
    const user = userEvent.setup();
    useLemonStore.setState({
      sessions: {
        ...initialState.sessions,
        activeSessionId: 'session-1',
      },
      toolExecutionsBySession: {
        'session-1': {
          t1: {
            id: 't1',
            name: 'read',
            args: { path: '/tmp/a' },
            status: 'running',
            startedAt: 1,
            updatedAt: 10,
          },
          t2: {
            id: 't2',
            name: 'bash',
            args: { command: 'ls' },
            status: 'error',
            startedAt: 2,
            updatedAt: 20,
          },
          t3: {
            id: 't3',
            name: 'write',
            args: { path: '/tmp/b' },
            status: 'complete',
            startedAt: 3,
            updatedAt: 30,
          },
        },
      },
    });

    const { container } = render(<ToolTimeline />);
    const scoped = within(container);

    expect(scoped.getByText('read')).toBeInTheDocument();
    expect(scoped.getByText('bash')).toBeInTheDocument();
    expect(scoped.getByText('write')).toBeInTheDocument();

    await user.click(scoped.getByRole('button', { name: 'error' }));

    expect(scoped.queryByText('read')).not.toBeInTheDocument();
    expect(scoped.getByText('bash')).toBeInTheDocument();
    expect(scoped.queryByText('write')).not.toBeInTheDocument();

    await user.click(scoped.getByRole('button', { name: 'complete' }));

    expect(scoped.queryByText('read')).not.toBeInTheDocument();
    expect(scoped.queryByText('bash')).not.toBeInTheDocument();
    expect(scoped.getByText('write')).toBeInTheDocument();
  });

  it('toggles detail sections and expand/collapse all', async () => {
    const user = userEvent.setup();
    useLemonStore.setState({
      sessions: {
        ...initialState.sessions,
        activeSessionId: 'session-2',
      },
      toolExecutionsBySession: {
        'session-2': {
          t1: {
            id: 't1',
            name: 'grep',
            args: { pattern: 'foo' },
            status: 'running',
            startedAt: 1,
            updatedAt: 10,
          },
        },
      },
    });

    const { container } = render(<ToolTimeline />);
    const scoped = within(container);

    expect(scoped.queryByText(/pattern/)).not.toBeInTheDocument();

    await user.click(scoped.getByRole('button', { name: /Args/ }));
    expect(scoped.getByText(/pattern/)).toBeInTheDocument();

    await user.click(scoped.getByRole('button', { name: /Args/ }));
    expect(scoped.queryByText(/pattern/)).not.toBeInTheDocument();

    await user.click(scoped.getByRole('button', { name: 'Expand all' }));
    expect(scoped.getByText(/pattern/)).toBeInTheDocument();

    await user.click(scoped.getByRole('button', { name: 'Collapse all' }));
    expect(scoped.queryByText(/pattern/)).not.toBeInTheDocument();
  });

  it('formats duration in seconds when over 1s', () => {
    useLemonStore.setState({
      sessions: {
        ...initialState.sessions,
        activeSessionId: 'session-3',
      },
      toolExecutionsBySession: {
        'session-3': {
          t1: {
            id: 't1',
            name: 'write',
            args: { path: '/tmp/c' },
            status: 'complete',
            startedAt: 1_000,
            updatedAt: 2_250,
            endedAt: 2_250,
          },
        },
      },
    });

    const { container } = render(<ToolTimeline />);
    const scoped = within(container);

    expect(scoped.getByText(/duration: 1\.3s/)).toBeInTheDocument();
  });

  it('formats duration in minutes when over 60s', () => {
    useLemonStore.setState({
      sessions: {
        ...initialState.sessions,
        activeSessionId: 'session-4',
      },
      toolExecutionsBySession: {
        'session-4': {
          t1: {
            id: 't1',
            name: 'grep',
            args: { pattern: 'bar' },
            status: 'complete',
            startedAt: 1_000,
            updatedAt: 91_100,
            endedAt: 91_100,
          },
        },
      },
    });

    const { container } = render(<ToolTimeline />);
    const scoped = within(container);

    expect(scoped.getByText(/duration: 1m 30\.1s/)).toBeInTheDocument();
  });
});
