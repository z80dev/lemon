import { useMemo, useState, useCallback } from 'react';
import type { ReactNode } from 'react';
import { useLemonStore } from '../store/useLemonStore';

const STATUS_FILTERS = ['all', 'running', 'complete', 'error'] as const;

type DetailKey = 'args' | 'partial' | 'result';
type StatusFilter = (typeof STATUS_FILTERS)[number];

type DetailState = Record<string, Record<DetailKey, boolean>>;

export function ToolTimeline() {
  const activeSessionId = useLemonStore((state) => state.sessions.activeSessionId);
  const toolExecutions = useLemonStore((state) =>
    activeSessionId ? state.toolExecutionsBySession[activeSessionId] : undefined
  );
  const [showAll, setShowAll] = useState(false);
  const [detailState, setDetailState] = useState<DetailState>({});
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('all');

  const toolList = useMemo(() => {
    if (!toolExecutions) return [];
    return Object.values(toolExecutions).sort((a, b) => b.updatedAt - a.updatedAt);
  }, [toolExecutions]);

  const filteredTools = useMemo(() => {
    if (statusFilter === 'all') return toolList;
    return toolList.filter((tool) => tool.status === statusFilter);
  }, [toolList, statusFilter]);

  const toggleDetail = useCallback((toolId: string, key: DetailKey) => {
    setDetailState((prev) => {
      const current = prev[toolId] ?? { args: false, partial: false, result: false };
      return {
        ...prev,
        [toolId]: {
          ...current,
          [key]: !current[key],
        },
      };
    });
  }, []);

  const formatDuration = useCallback((startedAt?: number, endedAt?: number, updatedAt?: number) => {
    if (!startedAt) return '–';
    const effectiveEnd = endedAt ?? updatedAt ?? startedAt;
    const durationMs = Math.max(0, effectiveEnd - startedAt);
    if (durationMs < 1000) return `${durationMs}ms`;
    const seconds = Math.round(durationMs / 100) / 10;
    if (seconds < 60) return `${seconds}s`;
    const minutes = Math.floor(seconds / 60);
    const remainder = Math.round((seconds % 60) * 10) / 10;
    return `${minutes}m ${remainder}s`;
  }, []);

  return (
    <section className="tool-timeline" aria-label="Tool execution timeline">
      <div className="chat-header">
        <h2>Tool Timeline</h2>
        <div className="tool-controls">
          <span className="chat-count" aria-live="polite">
            {toolList.length} {toolList.length === 1 ? 'call' : 'calls'}
          </span>
          {toolList.length > 0 ? (
            <button
              type="button"
              className="ghost-button"
              onClick={() => setShowAll((prev) => !prev)}
            >
              {showAll ? 'Collapse all' : 'Expand all'}
            </button>
          ) : null}
        </div>
      </div>
      {toolList.length > 0 ? (
        <div className="tool-filters" role="group" aria-label="Filter tool calls">
          {STATUS_FILTERS.map((filter) => (
            <button
              key={filter}
              type="button"
              className={`pill-button tool-filter ${statusFilter === filter ? 'tool-filter--active' : ''}`}
              onClick={() => setStatusFilter(filter)}
            >
              {filter}
            </button>
          ))}
        </div>
      ) : null}
      <div className="tool-timeline__list">
        {filteredTools.length === 0 ? (
          <p className="muted">No tools executed yet.</p>
        ) : (
          filteredTools.map((tool) => {
            const perTool = detailState[tool.id] ?? { args: false, partial: false, result: false };
            const durationLabel = formatDuration(tool.startedAt, tool.endedAt, tool.updatedAt);

            return (
              <div key={tool.id} className={`tool-card tool-card--${tool.status}`}>
                <div className="tool-card__header">
                  <span className="tool-card__name">{tool.name}</span>
                  <span className="tool-card__status">{tool.status}</span>
                </div>
                <div className="tool-card__meta">
                  <span>id: {tool.id}</span>
                  <span>duration: {durationLabel}</span>
                  <span>updated: {new Date(tool.updatedAt).toLocaleTimeString()}</span>
                </div>
                <div className="tool-card__details">
                  <DetailBlock
                    title="Args"
                    open={showAll || perTool.args}
                    onToggle={() => toggleDetail(tool.id, 'args')}
                  >
                    <pre>{JSON.stringify(tool.args, null, 2)}</pre>
                  </DetailBlock>
                  {tool.partial !== undefined ? (
                    <DetailBlock
                      title="Partial"
                      open={showAll || perTool.partial}
                      onToggle={() => toggleDetail(tool.id, 'partial')}
                    >
                      <pre>{JSON.stringify(tool.partial, null, 2)}</pre>
                    </DetailBlock>
                  ) : null}
                  {tool.result !== undefined ? (
                    <DetailBlock
                      title="Result"
                      open={showAll || perTool.result}
                      onToggle={() => toggleDetail(tool.id, 'result')}
                    >
                      <pre>{JSON.stringify(tool.result, null, 2)}</pre>
                    </DetailBlock>
                  ) : null}
                </div>
              </div>
            );
          })
        )}
      </div>
    </section>
  );
}

interface DetailBlockProps {
  title: string;
  open: boolean;
  onToggle: () => void;
  children: ReactNode;
}

function DetailBlock({ title, open, onToggle, children }: DetailBlockProps) {
  return (
    <div className={`tool-detail ${open ? 'tool-detail--open' : ''}`}>
      <button type="button" className="tool-detail__toggle" onClick={onToggle}>
        <span>{title}</span>
        <span className="tool-detail__chevron">{open ? '–' : '+'}</span>
      </button>
      {open ? <div className="tool-detail__body">{children}</div> : null}
    </div>
  );
}
