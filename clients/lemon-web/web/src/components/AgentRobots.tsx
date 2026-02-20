import { useMemo, type CSSProperties } from 'react';
import type { RunningSessionInfo } from '@lemon-web/shared';
import { useLemonStore } from '../store/useLemonStore';

type RobotCardStyle = CSSProperties & {
  '--robot-delay': string;
  '--robot-hue': string;
  '--robot-anchor-x': string;
  '--robot-anchor-y': string;
  '--robot-drift-x': string;
  '--robot-drift-y': string;
  '--robot-drift-x-half': string;
  '--robot-drift-y-half': string;
  '--robot-walk-duration': string;
  '--robot-step-duration': string;
  '--robot-scale': string;
  '--robot-depth': string;
};

function getAgentLabel(sessionId: string): string {
  if (!sessionId.startsWith('agent:')) {
    return sessionId;
  }

  const [, agentId] = sessionId.split(':');
  return agentId || sessionId;
}

function compactPath(path: string): string {
  const parts = path.split('/').filter(Boolean);
  if (parts.length < 3) {
    return path || '/';
  }

  return `.../${parts.slice(-2).join('/')}`;
}

function sortedSessions(running: Record<string, RunningSessionInfo>): RunningSessionInfo[] {
  return Object.values(running).sort((left, right) =>
    left.session_id.localeCompare(right.session_id)
  );
}

function buildRobotStyle(index: number, isStreaming: boolean): RobotCardStyle {
  const driftX = 16 + ((index * 11) % 20);
  const driftY = 10 + ((index * 7) % 16);
  const walkDuration = (isStreaming ? 5.8 : 7.4) + (index % 4) * 0.55;
  const stepDuration = (isStreaming ? 0.52 : 0.66) + (index % 3) * 0.06;

  return {
    '--robot-delay': `${-(index % 8) * 0.58}s`,
    '--robot-hue': `${145 + (index * 23) % 70}`,
    '--robot-anchor-x': `${14 + (index * 17) % 73}%`,
    '--robot-anchor-y': `${24 + (index * 19) % 54}%`,
    '--robot-drift-x': `${driftX}px`,
    '--robot-drift-y': `${driftY}px`,
    '--robot-drift-x-half': `${Math.floor(driftX * 0.55)}px`,
    '--robot-drift-y-half': `${Math.floor(driftY * 0.55)}px`,
    '--robot-walk-duration': `${walkDuration.toFixed(2)}s`,
    '--robot-step-duration': `${stepDuration.toFixed(2)}s`,
    '--robot-scale': `${(0.92 + (index % 4) * 0.05).toFixed(2)}`,
    '--robot-depth': `${index + 2}`,
  };
}

export function AgentRobots() {
  const runningSessions = useLemonStore((state) => state.sessions.running);

  const robots = useMemo(() => sortedSessions(runningSessions), [runningSessions]);

  return (
    <section className="agent-robots" aria-live="polite" aria-label="Running agents">
      <div className="agent-robots__header">
        <h2>Robot Agents</h2>
        <span className="agent-robots__count">{robots.length} online</span>
      </div>

      {robots.length === 0 ? (
        <p className="agent-robots__empty">
          No active robots right now. Start a session to wake one up.
        </p>
      ) : (
        <div className="agent-robots__arena">
          {robots.map((session, index) => {
            const cardStyle = buildRobotStyle(index, session.is_streaming);

            return (
              <article
                key={session.session_id}
                className={`agent-robot-card ${
                  session.is_streaming ? 'agent-robot-card--streaming' : 'agent-robot-card--idle'
                }`}
                style={cardStyle}
              >
                <div className="agent-robot-card__walker" aria-hidden="true">
                  <span className="robot-shadow" />
                  <div className="robot-3d">
                    <span className="robot-3d__antenna" />
                    <span className="robot-3d__head">
                      <span className="robot-3d__eye robot-3d__eye--left" />
                      <span className="robot-3d__eye robot-3d__eye--right" />
                      <span className="robot-3d__mouth" />
                    </span>

                    <span className="robot-3d__torso">
                      <span className="robot-3d__arm robot-3d__arm--left" />
                      <span className="robot-3d__arm robot-3d__arm--right" />
                      <span className="robot-3d__chest" />
                    </span>

                    <span className="robot-3d__legs">
                      <span className="robot-3d__leg robot-3d__leg--left" />
                      <span className="robot-3d__leg robot-3d__leg--right" />
                    </span>
                  </div>
                </div>

                <div className="agent-robot-card__meta">
                  <span className="agent-robot-card__name">{getAgentLabel(session.session_id)}</span>
                  <span className="agent-robot-card__session" title={session.session_id}>
                    {session.session_id}
                  </span>
                  <span className="agent-robot-card__cwd" title={session.cwd}>
                    {compactPath(session.cwd)}
                  </span>
                  <span
                    className={`agent-robot-card__status ${
                      session.is_streaming ? 'agent-robot-card__status--streaming' : ''
                    }`}
                  >
                    {session.is_streaming ? 'Thinking' : 'Idle'}
                  </span>
                </div>
              </article>
            );
          })}
        </div>
      )}
    </section>
  );
}
