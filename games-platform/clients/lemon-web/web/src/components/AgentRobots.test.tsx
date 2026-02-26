import { render, screen } from '@testing-library/react';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import type { RunningSessionInfo } from '@lemon-web/shared';
import { AgentRobots } from './AgentRobots';
import { useLemonStore, type LemonState } from '../store/useLemonStore';

function setRunningSessions(sessions: RunningSessionInfo[]) {
  const running: Record<string, RunningSessionInfo> = {};
  for (const session of sessions) {
    running[session.session_id] = session;
  }

  useLemonStore.setState({
    sessions: {
      running,
      saved: [],
      activeSessionId: null,
      primarySessionId: null,
    },
  } as LemonState);
}

describe('AgentRobots', () => {
  beforeEach(() => {
    setRunningSessions([]);
  });

  afterEach(() => {
    setRunningSessions([]);
  });

  it('shows the empty state when there are no running sessions', () => {
    render(<AgentRobots />);

    expect(screen.getByText('0 online')).toBeInTheDocument();
    expect(
      screen.getByText('No active robots right now. Start a session to wake one up.')
    ).toBeInTheDocument();
  });

  it('renders one robot card per running session', () => {
    setRunningSessions([
      {
        session_id: 'agent:planner:main',
        cwd: '/Users/z80/dev/lemon',
        is_streaming: false,
      },
      {
        session_id: 'agent:writer:main',
        cwd: '/Users/z80/dev/docs',
        is_streaming: true,
      },
    ]);

    render(<AgentRobots />);

    expect(document.querySelectorAll('.agent-robot-card')).toHaveLength(2);
    expect(screen.getByText('2 online')).toBeInTheDocument();
  });

  it('derives a friendly agent label from agent session keys', () => {
    setRunningSessions([
      {
        session_id: 'agent:ops-bot:telegram:bot:dm:123',
        cwd: '/Users/z80/dev/lemon',
        is_streaming: false,
      },
    ]);

    render(<AgentRobots />);

    expect(screen.getByText('ops-bot')).toBeInTheDocument();
    expect(screen.getByText('agent:ops-bot:telegram:bot:dm:123')).toBeInTheDocument();
  });

  it('uses the full session id as label when not in agent:key format', () => {
    setRunningSessions([
      {
        session_id: 'session-123',
        cwd: '/Users/z80/dev/lemon',
        is_streaming: false,
      },
    ]);

    render(<AgentRobots />);

    const labels = screen.getAllByText('session-123');
    expect(labels.length).toBeGreaterThanOrEqual(1);
  });

  it('shows streaming sessions as Thinking with the streaming class', () => {
    setRunningSessions([
      {
        session_id: 'agent:streamer:main',
        cwd: '/Users/z80/dev/lemon',
        is_streaming: true,
      },
    ]);

    render(<AgentRobots />);

    expect(screen.getByText('Thinking')).toBeInTheDocument();
    const card = document.querySelector('.agent-robot-card');
    expect(card).toHaveClass('agent-robot-card--streaming');
  });

  it('sorts sessions by session id for stable ordering', () => {
    setRunningSessions([
      {
        session_id: 'agent:zeta:main',
        cwd: '/tmp/zeta',
        is_streaming: false,
      },
      {
        session_id: 'agent:alpha:main',
        cwd: '/tmp/alpha',
        is_streaming: false,
      },
    ]);

    render(<AgentRobots />);

    const sessionNodes = Array.from(document.querySelectorAll('.agent-robot-card__session'));
    const orderedIds = sessionNodes.map((node) => node.textContent);

    expect(orderedIds).toEqual(['agent:alpha:main', 'agent:zeta:main']);
  });
});
