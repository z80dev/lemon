import { useMemo } from 'react';
import { useLemonStore } from '../store/useLemonStore';

export function ToolTimeline() {
  const activeSessionId = useLemonStore((state) => state.sessions.activeSessionId);
  const toolExecutions = useLemonStore((state) =>
    activeSessionId ? state.toolExecutionsBySession[activeSessionId] : undefined
  );

  const toolList = useMemo(() => {
    if (!toolExecutions) return [];
    return Object.values(toolExecutions).sort((a, b) => b.updatedAt - a.updatedAt);
  }, [toolExecutions]);

  return (
    <section className="tool-timeline">
      <div className="chat-header">
        <h2>Tool Timeline</h2>
        <span className="chat-count">{toolList.length} calls</span>
      </div>
      <div className="tool-timeline__list">
        {toolList.length === 0 ? (
          <p className="muted">No tools executed yet.</p>
        ) : (
          toolList.map((tool) => (
            <div key={tool.id} className={`tool-card tool-card--${tool.status}`}>
              <div className="tool-card__header">
                <span className="tool-card__name">{tool.name}</span>
                <span className="tool-card__status">{tool.status}</span>
              </div>
              <div className="tool-card__meta">
                <span>id: {tool.id}</span>
                <span>
                  updated: {new Date(tool.updatedAt).toLocaleTimeString()}
                </span>
              </div>
              <details>
                <summary>Args</summary>
                <pre>{JSON.stringify(tool.args, null, 2)}</pre>
              </details>
              {tool.partial !== undefined ? (
                <details>
                  <summary>Partial</summary>
                  <pre>{JSON.stringify(tool.partial, null, 2)}</pre>
                </details>
              ) : null}
              {tool.result !== undefined ? (
                <details>
                  <summary>Result</summary>
                  <pre>{JSON.stringify(tool.result, null, 2)}</pre>
                </details>
              ) : null}
            </div>
          ))
        )}
      </div>
    </section>
  );
}
