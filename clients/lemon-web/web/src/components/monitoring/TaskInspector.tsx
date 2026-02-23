import { useMemo } from 'react';
import { useMonitoringStore } from '../../store/monitoringStore';
import type { MonitoringTask } from '../../../../shared/src/monitoringTypes';

function formatDuration(ms: number | null): string {
  if (ms == null) return '--';
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
  return `${Math.floor(ms / 60_000)}m ${Math.floor((ms % 60_000) / 1000)}s`;
}

const STATUS_STYLES: Record<string, { bg: string; color: string }> = {
  active: { bg: '#002244', color: '#5599ff' },
  completed: { bg: '#003322', color: '#00ff88' },
  error: { bg: '#330000', color: '#ff4444' },
  timeout: { bg: '#332200', color: '#ffaa00' },
  aborted: { bg: '#222', color: '#888' },
};

interface TaskNodeProps {
  task: MonitoringTask;
  childTasks: MonitoringTask[];
  depth: number;
}

function TaskNode({ task, childTasks, depth }: TaskNodeProps) {
  const statusStyle = STATUS_STYLES[task.status] ?? STATUS_STYLES['aborted'];

  return (
    <div style={{ marginLeft: `${depth * 16}px` }}>
      <div
        data-testid={`task-node-${task.taskId}`}
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: '8px',
          padding: '4px 8px',
          borderBottom: '1px solid #1a1a1a',
        }}
      >
        <span style={{ color: '#666', width: '16px', textAlign: 'center' }}>
          {depth === 0 ? '\u25B6' : '\u251C'}
        </span>
        <span style={{ color: '#5599ff', minWidth: '80px' }}>
          {task.taskId.length > 12 ? task.taskId.slice(0, 12) + '\u2026' : task.taskId}
        </span>
        <span
          style={{
            padding: '1px 5px',
            borderRadius: '3px',
            background: statusStyle.bg,
            color: statusStyle.color,
            fontSize: '10px',
            textTransform: 'uppercase',
          }}
        >
          {task.status}
        </span>
        <span style={{ color: '#888' }}>{formatDuration(task.durationMs)}</span>
        {task.agentId && <span style={{ color: '#aaa' }}>{task.agentId}</span>}
      </div>
      {childTasks.map((child) => (
        <TaskNode key={child.taskId} task={child} childTasks={[]} depth={depth + 1} />
      ))}
    </div>
  );
}

export function TaskInspector() {
  const selectedRunId = useMonitoringStore((s) => s.ui.selectedRunId);
  const activeTasks = useMonitoringStore((s) => s.tasks.active);
  const recentTasks = useMonitoringStore((s) => s.tasks.recent);

  const allTasks = useMemo<MonitoringTask[]>(() => {
    const combined = [...Object.values(activeTasks), ...recentTasks];
    if (!selectedRunId) return combined;
    return combined.filter(
      (t) => t.parentRunId === selectedRunId || t.runId === selectedRunId
    );
  }, [selectedRunId, activeTasks, recentTasks]);

  const { rootTasks, childMap } = useMemo(() => {
    const roots: MonitoringTask[] = [];
    const children = new Map<string, MonitoringTask[]>();

    for (const task of allTasks) {
      const parentKey = task.parentRunId;
      if (parentKey && parentKey !== selectedRunId) {
        const list = children.get(parentKey) ?? [];
        list.push(task);
        children.set(parentKey, list);
      } else {
        roots.push(task);
      }
    }

    return { rootTasks: roots, childMap: children };
  }, [allTasks, selectedRunId]);

  if (!selectedRunId) {
    return (
      <div
        data-testid="task-inspector"
        style={{
          fontFamily: 'monospace',
          fontSize: '12px',
          color: '#666',
          padding: '40px',
          textAlign: 'center',
        }}
      >
        Select a run to view its task tree
      </div>
    );
  }

  return (
    <div data-testid="task-inspector" style={{ fontFamily: 'monospace', fontSize: '11px', color: '#e0e0e0' }}>
      <div style={{ fontWeight: 'bold', fontSize: '13px', marginBottom: '12px' }}>
        Task Tree
        <span style={{ color: '#888', fontWeight: 'normal', fontSize: '11px', marginLeft: '8px' }}>
          run: {selectedRunId}
        </span>
      </div>

      {rootTasks.length === 0 ? (
        <div style={{ color: '#666', padding: '16px' }}>No tasks for this run</div>
      ) : (
        rootTasks.map((task) => (
          <TaskNode
            key={task.taskId}
            task={task}
            childTasks={childMap.get(task.taskId) ?? []}
            depth={0}
          />
        ))
      )}
    </div>
  );
}
