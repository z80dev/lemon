import { describe, it, expect, beforeEach } from 'vitest';
import { useMonitoringStore, INITIAL_INSTANCE, INITIAL_UI } from './monitoringStore';
import {
  applyHelloOk,
  applyEvent,
  applyRunsActiveList,
  applyRunsRecentList,
  applySessionsActiveList,
  applyTasksActiveList,
  applyTasksRecentList,
  addFeedEvent,
  pruneFeedEvents,
  MAX_FEED_EVENTS,
} from './monitoringReducers';
import type { MonitoringState } from './monitoringStore';
import type { FeedEvent, MonitoringRun, MonitoringTask } from '../../../shared/src/monitoringTypes';

// ============================================================================
// Test helpers
// ============================================================================

function makeInitialState(): MonitoringState {
  return {
    instance: { ...INITIAL_INSTANCE },
    agents: {},
    sessions: {
      active: {},
      historical: [],
      selectedSessionKey: null,
      loadedSessionKeys: new Set(),
    },
    runs: { active: {}, recent: [] },
    tasks: { active: {}, recent: [] },
    eventFeed: [],
    ui: {
      ...INITIAL_UI,
      filters: { ...INITIAL_UI.filters, eventTypes: [] },
    },
    // Actions are not needed for reducer tests
    applyHelloOk: () => {},
    applyEvent: () => {},
    applyRunsActiveList: () => {},
    applyRunsRecentList: () => {},
    applySessionsActiveList: () => {},
    applySessionsList: () => {},
    applyTasksActiveList: () => {},
    applyTasksRecentList: () => {},
    applySnapshot: () => {},
    setSelectedSession: () => {},
    setSelectedRun: () => {},
    setUIFilter: () => {},
    setEventFeedPaused: () => {},
    clearEventFeed: () => {},
    resetMonitoring: () => {},
  };
}

function makeRun(overrides: Partial<MonitoringRun> = {}): MonitoringRun {
  return {
    runId: 'run-1',
    sessionKey: null,
    agentId: null,
    engine: null,
    startedAtMs: Date.now(),
    completedAtMs: null,
    durationMs: null,
    status: 'active',
    ok: null,
    parentRunId: null,
    ...overrides,
  };
}

function makeTask(overrides: Partial<MonitoringTask> = {}): MonitoringTask {
  return {
    taskId: 'task-1',
    parentRunId: null,
    runId: null,
    sessionKey: null,
    agentId: null,
    startedAtMs: Date.now(),
    completedAtMs: null,
    durationMs: null,
    status: 'active',
    ...overrides,
  };
}

// ============================================================================
// 1. Initial state tests
// ============================================================================

describe('useMonitoringStore initial state', () => {
  beforeEach(() => {
    useMonitoringStore.getState().resetMonitoring();
  });

  it('has correct initial instance health', () => {
    const state = useMonitoringStore.getState();
    expect(state.instance.status).toBe('unknown');
    expect(state.instance.uptimeMs).toBeNull();
    expect(state.instance.connectedClients).toBe(0);
    expect(state.instance.activeRuns).toBe(0);
    expect(state.instance.nodeId).toBeNull();
    expect(state.instance.version).toBeNull();
    expect(state.instance.lastUpdatedMs).toBeNull();
  });

  it('has empty slices on init', () => {
    const state = useMonitoringStore.getState();
    expect(state.agents).toEqual({});
    expect(state.sessions.active).toEqual({});
    expect(state.sessions.historical).toEqual([]);
    expect(state.runs.active).toEqual({});
    expect(state.runs.recent).toEqual([]);
    expect(state.tasks.active).toEqual({});
    expect(state.tasks.recent).toEqual([]);
    expect(state.eventFeed).toEqual([]);
  });

  it('has correct initial UI state', () => {
    const state = useMonitoringStore.getState();
    expect(state.ui.selectedSessionKey).toBeNull();
    expect(state.ui.selectedRunId).toBeNull();
    expect(state.ui.eventFeedPaused).toBe(false);
    expect(state.ui.sidebarTab).toBe('sessions');
    expect(state.ui.filters.agentId).toBeNull();
    expect(state.ui.filters.eventTypes).toEqual([]);
  });
});

// ============================================================================
// 2. applyHelloOk reducer
// ============================================================================

describe('applyHelloOk reducer', () => {
  it('updates instance version, nodeId, uptimeMs and sets status to healthy', () => {
    const state = makeInitialState();
    const next = applyHelloOk(state, {
      server: { version: '1.2.3', nodeId: 'node-abc', uptimeMs: 50000 },
      features: {},
    });

    expect(next.instance.version).toBe('1.2.3');
    expect(next.instance.nodeId).toBe('node-abc');
    expect(next.instance.uptimeMs).toBe(50000);
    expect(next.instance.status).toBe('healthy');
    expect(next.instance.lastUpdatedMs).toBeTypeOf('number');
  });

  it('applies snapshot if provided', () => {
    const state = makeInitialState();
    const next = applyHelloOk(state, {
      server: { version: '2.0.0' },
      features: {},
      snapshot: {
        sessions: [
          { session_key: 'sess-1', active: true },
        ],
      },
    });

    expect(next.sessions.active['sess-1']).toBeDefined();
    expect(next.sessions.active['sess-1'].sessionKey).toBe('sess-1');
  });

  it('does not crash when server fields are missing', () => {
    const state = makeInitialState();
    const next = applyHelloOk(state, {
      server: {},
      features: {},
    });
    expect(next.instance.status).toBe('healthy');
    expect(next.instance.version).toBeNull();
  });
});

// ============================================================================
// 3. applyEvent - agent started
// ============================================================================

describe('applyEvent("agent", {type:"started",...})', () => {
  it('adds run to active runs', () => {
    const state = makeInitialState();
    const next = applyEvent(state, 'agent', {
      type: 'started',
      run_id: 'run-42',
      session_key: 'sess-1',
      agent_id: 'agent-1',
      engine: 'claude',
    }, 1);

    expect(next.runs.active['run-42']).toBeDefined();
    expect(next.runs.active['run-42'].runId).toBe('run-42');
    expect(next.runs.active['run-42'].sessionKey).toBe('sess-1');
    expect(next.runs.active['run-42'].agentId).toBe('agent-1');
    expect(next.runs.active['run-42'].status).toBe('active');
  });

  it('updates instance.activeRuns count', () => {
    const state = makeInitialState();
    const next = applyEvent(state, 'agent', { type: 'started', run_id: 'run-1' }, 1);
    expect(next.instance.activeRuns).toBe(1);
  });

  it('adds event to feed', () => {
    const state = makeInitialState();
    const next = applyEvent(state, 'agent', { type: 'started', run_id: 'run-1' }, 1);
    expect(next.eventFeed).toHaveLength(1);
    expect(next.eventFeed[0].eventName).toBe('agent');
  });

  it('ignores started event without run_id gracefully', () => {
    const state = makeInitialState();
    const next = applyEvent(state, 'agent', { type: 'started' }, 1);
    expect(Object.keys(next.runs.active)).toHaveLength(0);
    // Still adds to feed
    expect(next.eventFeed).toHaveLength(1);
  });
});

// ============================================================================
// 4. applyEvent - agent completed
// ============================================================================

describe('applyEvent("agent", {type:"completed",...})', () => {
  it('moves run from active to recent and updates status', () => {
    let state = makeInitialState();
    // First add an active run
    state = applyEvent(state, 'agent', { type: 'started', run_id: 'run-99' }, 1);
    expect(state.runs.active['run-99']).toBeDefined();

    // Now complete it
    state = applyEvent(state, 'agent', { type: 'completed', run_id: 'run-99', ok: true }, 2);

    expect(state.runs.active['run-99']).toBeUndefined();
    expect(state.runs.recent).toHaveLength(1);
    expect(state.runs.recent[0].runId).toBe('run-99');
    expect(state.runs.recent[0].status).toBe('completed');
    expect(state.runs.recent[0].ok).toBe(true);
  });

  it('marks run as error when ok is false', () => {
    let state = makeInitialState();
    state = applyEvent(state, 'agent', { type: 'started', run_id: 'run-x' }, 1);
    state = applyEvent(state, 'agent', { type: 'completed', run_id: 'run-x', ok: false }, 2);

    expect(state.runs.recent[0].status).toBe('error');
    expect(state.runs.recent[0].ok).toBe(false);
  });

  it('decrements instance.activeRuns', () => {
    let state = makeInitialState();
    state = applyEvent(state, 'agent', { type: 'started', run_id: 'run-a' }, 1);
    state = applyEvent(state, 'agent', { type: 'started', run_id: 'run-b' }, 2);
    expect(state.instance.activeRuns).toBe(2);

    state = applyEvent(state, 'agent', { type: 'completed', run_id: 'run-a', ok: true }, 3);
    expect(state.instance.activeRuns).toBe(1);
  });

  it('handles completion of unknown run gracefully', () => {
    const state = makeInitialState();
    // Completing a run that was never started
    const next = applyEvent(state, 'agent', { type: 'completed', run_id: 'unknown-run' }, 1);
    expect(next.runs.recent).toHaveLength(1);
    expect(next.runs.recent[0].runId).toBe('unknown-run');
  });
});

// ============================================================================
// 5. applyEvent - task.started
// ============================================================================

describe('applyEvent("task.started", {...})', () => {
  it('adds task to active tasks', () => {
    const state = makeInitialState();
    const next = applyEvent(state, 'task.started', {
      task_id: 'task-10',
      run_id: 'run-1',
      session_key: 'sess-1',
    }, 1);

    expect(next.tasks.active['task-10']).toBeDefined();
    expect(next.tasks.active['task-10'].taskId).toBe('task-10');
    expect(next.tasks.active['task-10'].runId).toBe('run-1');
    expect(next.tasks.active['task-10'].status).toBe('active');
  });

  it('adds task event to feed', () => {
    const state = makeInitialState();
    const next = applyEvent(state, 'task.started', { task_id: 'task-10' }, 1);
    expect(next.eventFeed).toHaveLength(1);
    expect(next.eventFeed[0].eventName).toBe('task.started');
    expect(next.eventFeed[0].level).toBe('info');
  });
});

// ============================================================================
// 6. applyEvent - task completed/error/timeout/aborted
// ============================================================================

describe('applyEvent task completion variants', () => {
  it('moves task.completed to recent', () => {
    let state = makeInitialState();
    state = applyEvent(state, 'task.started', { task_id: 'task-1' }, 1);
    state = applyEvent(state, 'task.completed', { task_id: 'task-1' }, 2);

    expect(state.tasks.active['task-1']).toBeUndefined();
    expect(state.tasks.recent).toHaveLength(1);
    expect(state.tasks.recent[0].status).toBe('completed');
  });

  it('task.error sets status to error and level to warn', () => {
    let state = makeInitialState();
    state = applyEvent(state, 'task.started', { task_id: 'task-e' }, 1);
    state = applyEvent(state, 'task.error', { task_id: 'task-e' }, 2);

    expect(state.tasks.recent[0].status).toBe('error');
    // The feed event should be 'warn'
    const errorFeedEvent = state.eventFeed.find((e) => e.eventName === 'task.error');
    expect(errorFeedEvent?.level).toBe('warn');
  });

  it('task.timeout sets status to timeout and level to warn', () => {
    let state = makeInitialState();
    state = applyEvent(state, 'task.started', { task_id: 'task-t' }, 1);
    state = applyEvent(state, 'task.timeout', { task_id: 'task-t' }, 2);

    expect(state.tasks.recent[0].status).toBe('timeout');
    const timeoutEvent = state.eventFeed.find((e) => e.eventName === 'task.timeout');
    expect(timeoutEvent?.level).toBe('warn');
  });

  it('task.aborted sets status to aborted', () => {
    let state = makeInitialState();
    state = applyEvent(state, 'task.started', { task_id: 'task-ab' }, 1);
    state = applyEvent(state, 'task.aborted', { task_id: 'task-ab' }, 2);

    expect(state.tasks.recent[0].status).toBe('aborted');
  });
});

// ============================================================================
// 7. applyEvent - presence
// ============================================================================

describe('applyEvent("presence", {...})', () => {
  it('updates instance.connectedClients', () => {
    const state = makeInitialState();
    const next = applyEvent(state, 'presence', { count: 5 }, 1);
    expect(next.instance.connectedClients).toBe(5);
  });

  it('accepts connected_clients field as well', () => {
    const state = makeInitialState();
    const next = applyEvent(state, 'presence', { connected_clients: 3 }, 1);
    expect(next.instance.connectedClients).toBe(3);
  });

  it('adds presence to feed', () => {
    const state = makeInitialState();
    const next = applyEvent(state, 'presence', { count: 2 }, 1);
    expect(next.eventFeed).toHaveLength(1);
    expect(next.eventFeed[0].eventName).toBe('presence');
  });
});

// ============================================================================
// 8. applyEvent - heartbeat
// ============================================================================

describe('applyEvent("heartbeat", {...})', () => {
  it('updates uptimeMs and sets status to healthy', () => {
    const state = makeInitialState();
    const next = applyEvent(state, 'heartbeat', { uptime_ms: 123456 }, 1);
    expect(next.instance.uptimeMs).toBe(123456);
    expect(next.instance.status).toBe('healthy');
    expect(next.instance.lastUpdatedMs).toBeTypeOf('number');
  });
});

// ============================================================================
// 9. applyEvent always adds to eventFeed
// ============================================================================

describe('applyEvent always adds to eventFeed', () => {
  it('adds unknown event types to feed without crashing', () => {
    const state = makeInitialState();
    const next = applyEvent(state, 'some.unknown.event', { foo: 'bar' }, 42);
    expect(next.eventFeed).toHaveLength(1);
    expect(next.eventFeed[0].eventName).toBe('some.unknown.event');
    expect(next.eventFeed[0].seq).toBe(42);
    expect(next.eventFeed[0].level).toBe('info');
  });

  it('chat event is added to feed', () => {
    const state = makeInitialState();
    const next = applyEvent(state, 'chat', { message: 'hello' }, 5);
    expect(next.eventFeed).toHaveLength(1);
    expect(next.eventFeed[0].eventName).toBe('chat');
  });

  it('run.graph.changed event is added to feed', () => {
    const state = makeInitialState();
    const next = applyEvent(state, 'run.graph.changed', { run_id: 'r1' }, 3);
    expect(next.eventFeed).toHaveLength(1);
  });

  it('health event with non-ok status has warn level', () => {
    const state = makeInitialState();
    const next = applyEvent(state, 'health', { status: 'degraded' }, 1);
    expect(next.eventFeed[0].level).toBe('warn');
  });

  it('health event with healthy status has info level', () => {
    const state = makeInitialState();
    const next = applyEvent(state, 'health', { status: 'healthy' }, 1);
    expect(next.eventFeed[0].level).toBe('info');
  });
});

// ============================================================================
// 10. Event feed capping
// ============================================================================

describe('Event feed capping', () => {
  it('caps feed at MAX_FEED_EVENTS', () => {
    let feed: FeedEvent[] = [];
    // Add MAX_FEED_EVENTS + 1 entries
    for (let i = 0; i <= MAX_FEED_EVENTS; i++) {
      feed = [...feed, {
        id: `feed-${i}`,
        eventName: 'test',
        payload: null,
        seq: i,
        receivedAtMs: Date.now(),
        level: 'info',
      }];
    }
    const pruned = pruneFeedEvents(feed);
    expect(pruned).toHaveLength(MAX_FEED_EVENTS);
  });

  it('keeps newest events when pruning', () => {
    let feed: FeedEvent[] = [];
    for (let i = 0; i < MAX_FEED_EVENTS + 10; i++) {
      feed = [...feed, {
        id: `feed-${i}`,
        eventName: 'test',
        payload: { index: i },
        seq: i,
        receivedAtMs: Date.now(),
        level: 'info',
      }];
    }
    const pruned = pruneFeedEvents(feed);
    // Should keep the last MAX_FEED_EVENTS - starting from index 10
    expect(pruned[0].seq).toBe(10);
    expect(pruned[pruned.length - 1].seq).toBe(MAX_FEED_EVENTS + 9);
  });

  it('does not prune when under limit', () => {
    const feed: FeedEvent[] = Array.from({ length: 10 }, (_, i) => ({
      id: `feed-${i}`,
      eventName: 'test',
      payload: null,
      seq: i,
      receivedAtMs: Date.now(),
      level: 'info' as const,
    }));
    const pruned = pruneFeedEvents(feed);
    expect(pruned).toHaveLength(10);
  });
});

// ============================================================================
// 11. applyRunsActiveList
// ============================================================================

describe('applyRunsActiveList', () => {
  it('replaces active runs completely', () => {
    let state = makeInitialState();
    // Seed with existing run
    state = { ...state, runs: { ...state.runs, active: { 'old-run': makeRun({ runId: 'old-run' }) } } };

    const newRuns = [makeRun({ runId: 'run-a' }), makeRun({ runId: 'run-b' })];
    const next = applyRunsActiveList(state, { runs: newRuns, total: 2 });

    expect(next.runs.active['old-run']).toBeUndefined();
    expect(next.runs.active['run-a']).toBeDefined();
    expect(next.runs.active['run-b']).toBeDefined();
  });

  it('updates instance.activeRuns', () => {
    const state = makeInitialState();
    const newRuns = [makeRun({ runId: 'r1' }), makeRun({ runId: 'r2' }), makeRun({ runId: 'r3' })];
    const next = applyRunsActiveList(state, { runs: newRuns, total: 3 });
    expect(next.instance.activeRuns).toBe(3);
  });
});

// ============================================================================
// 12. applyRunsRecentList
// ============================================================================

describe('applyRunsRecentList', () => {
  it('replaces recent runs', () => {
    let state = makeInitialState();
    state = { ...state, runs: { ...state.runs, recent: [makeRun({ runId: 'old-recent', status: 'completed' })] } };

    const newRuns = [
      makeRun({ runId: 'new-1', status: 'completed' }),
      makeRun({ runId: 'new-2', status: 'error' }),
    ];
    const next = applyRunsRecentList(state, { runs: newRuns, total: 2 });

    expect(next.runs.recent).toHaveLength(2);
    expect(next.runs.recent[0].runId).toBe('new-1');
    expect(next.runs.recent[1].runId).toBe('new-2');
  });
});

// ============================================================================
// 13. applySessionsActiveList
// ============================================================================

describe('applySessionsActiveList', () => {
  it('updates active sessions from list', () => {
    const state = makeInitialState();
    const next = applySessionsActiveList(state, [
      { session_key: 'sess-a', active: true, agent_id: 'agent-1' },
      { session_key: 'sess-b', active: false },
    ]);

    expect(next.sessions.active['sess-a']).toBeDefined();
    expect(next.sessions.active['sess-a'].agentId).toBe('agent-1');
    expect(next.sessions.active['sess-b']).toBeDefined();
  });

  it('ignores entries without session_key', () => {
    const state = makeInitialState();
    const next = applySessionsActiveList(state, [
      { active: true },
      { session_key: 'valid-sess', active: true },
    ]);

    expect(Object.keys(next.sessions.active)).toHaveLength(1);
    expect(next.sessions.active['valid-sess']).toBeDefined();
  });

  it('replaces previous active sessions', () => {
    let state = makeInitialState();
    state = applySessionsActiveList(state, [{ session_key: 'old-sess', active: true }]);
    expect(state.sessions.active['old-sess']).toBeDefined();

    const next = applySessionsActiveList(state, [{ session_key: 'new-sess', active: true }]);
    expect(next.sessions.active['old-sess']).toBeUndefined();
    expect(next.sessions.active['new-sess']).toBeDefined();
  });
});

// ============================================================================
// 14. setSelectedSession store action
// ============================================================================

describe('setSelectedSession store action', () => {
  beforeEach(() => {
    useMonitoringStore.getState().resetMonitoring();
  });

  it('updates ui.selectedSessionKey', () => {
    useMonitoringStore.getState().setSelectedSession('sess-foo');
    expect(useMonitoringStore.getState().ui.selectedSessionKey).toBe('sess-foo');
  });

  it('can clear selection with null', () => {
    useMonitoringStore.getState().setSelectedSession('sess-foo');
    useMonitoringStore.getState().setSelectedSession(null);
    expect(useMonitoringStore.getState().ui.selectedSessionKey).toBeNull();
  });

  it('updates sessions.selectedSessionKey', () => {
    useMonitoringStore.getState().setSelectedSession('sess-bar');
    expect(useMonitoringStore.getState().sessions.selectedSessionKey).toBe('sess-bar');
  });
});

// ============================================================================
// 15. setUIFilter store action
// ============================================================================

describe('setUIFilter store action', () => {
  beforeEach(() => {
    useMonitoringStore.getState().resetMonitoring();
  });

  it('updates a string filter', () => {
    useMonitoringStore.getState().setUIFilter('agentId', 'agent-42');
    expect(useMonitoringStore.getState().ui.filters.agentId).toBe('agent-42');
  });

  it('updates eventTypes filter', () => {
    useMonitoringStore.getState().setUIFilter('eventTypes', ['agent', 'task.started']);
    expect(useMonitoringStore.getState().ui.filters.eventTypes).toEqual(['agent', 'task.started']);
  });

  it('does not affect other filters', () => {
    useMonitoringStore.getState().setUIFilter('agentId', 'a1');
    useMonitoringStore.getState().setUIFilter('status', 'active');
    expect(useMonitoringStore.getState().ui.filters.agentId).toBe('a1');
    expect(useMonitoringStore.getState().ui.filters.status).toBe('active');
    expect(useMonitoringStore.getState().ui.filters.runId).toBeNull();
  });
});

// ============================================================================
// 16. clearEventFeed store action
// ============================================================================

describe('clearEventFeed store action', () => {
  beforeEach(() => {
    useMonitoringStore.getState().resetMonitoring();
  });

  it('clears the event feed', () => {
    // Add some events via the store action
    useMonitoringStore.getState().applyEvent('chat', { message: 'hi' }, 1);
    useMonitoringStore.getState().applyEvent('chat', { message: 'hello' }, 2);
    expect(useMonitoringStore.getState().eventFeed.length).toBeGreaterThan(0);

    useMonitoringStore.getState().clearEventFeed();
    expect(useMonitoringStore.getState().eventFeed).toHaveLength(0);
  });
});

// ============================================================================
// 17. resetMonitoring store action
// ============================================================================

describe('resetMonitoring store action', () => {
  beforeEach(() => {
    useMonitoringStore.getState().resetMonitoring();
  });

  it('returns to initial state after modifications', () => {
    const store = useMonitoringStore.getState();
    store.applyEvent('agent', { type: 'started', run_id: 'r1' }, 1);
    store.setSelectedSession('sess-x');
    store.setUIFilter('agentId', 'agent-z');

    expect(useMonitoringStore.getState().runs.active['r1']).toBeDefined();

    useMonitoringStore.getState().resetMonitoring();
    const reset = useMonitoringStore.getState();

    expect(reset.runs.active).toEqual({});
    expect(reset.runs.recent).toEqual([]);
    expect(reset.eventFeed).toEqual([]);
    expect(reset.ui.selectedSessionKey).toBeNull();
    expect(reset.ui.filters.agentId).toBeNull();
    expect(reset.instance.status).toBe('unknown');
  });
});

// ============================================================================
// 18. Immutable updates (concurrent state correctness)
// ============================================================================

describe('Immutable state updates', () => {
  it('does not mutate previous state when adding a run', () => {
    const state = makeInitialState();
    const stateBefore = state.runs.active;

    const next = applyEvent(state, 'agent', { type: 'started', run_id: 'r1' }, 1);

    // Original state.runs.active should be unchanged
    expect(stateBefore).toEqual({});
    expect(next.runs.active).not.toBe(stateBefore);
    expect(next.runs.active['r1']).toBeDefined();
  });

  it('does not mutate previous feed when adding an event', () => {
    const state = makeInitialState();
    const feedBefore = state.eventFeed;

    const next = addFeedEvent(state, {
      eventName: 'test',
      payload: null,
      seq: 1,
      level: 'info',
    });

    expect(feedBefore).toHaveLength(0);
    expect(next.eventFeed).toHaveLength(1);
    expect(next.eventFeed).not.toBe(feedBefore);
  });

  it('does not mutate tasks when completing a task', () => {
    let state = makeInitialState();
    state = applyEvent(state, 'task.started', { task_id: 'task-1' }, 1);

    const activeBefore = state.tasks.active;
    const next = applyEvent(state, 'task.completed', { task_id: 'task-1' }, 2);

    // activeBefore should still have the task; next should not
    expect(activeBefore['task-1']).toBeDefined();
    expect(next.tasks.active['task-1']).toBeUndefined();
  });
});

// ============================================================================
// 19. applyTasksActiveList and applyTasksRecentList
// ============================================================================

describe('applyTasksActiveList', () => {
  it('replaces active tasks', () => {
    const state = makeInitialState();
    const tasks = [
      makeTask({ taskId: 'task-a' }),
      makeTask({ taskId: 'task-b' }),
    ];
    const next = applyTasksActiveList(state, tasks);
    expect(next.tasks.active['task-a']).toBeDefined();
    expect(next.tasks.active['task-b']).toBeDefined();
  });
});

describe('applyTasksRecentList', () => {
  it('replaces recent tasks', () => {
    const state = makeInitialState();
    const tasks = [makeTask({ taskId: 'task-r1', status: 'completed' })];
    const next = applyTasksRecentList(state, tasks);
    expect(next.tasks.recent).toHaveLength(1);
    expect(next.tasks.recent[0].taskId).toBe('task-r1');
  });
});

// ============================================================================
// 20. setEventFeedPaused - events not added when paused
// ============================================================================

describe('setEventFeedPaused', () => {
  beforeEach(() => {
    useMonitoringStore.getState().resetMonitoring();
  });

  it('pauses event feed additions', () => {
    useMonitoringStore.getState().setEventFeedPaused(true);
    useMonitoringStore.getState().applyEvent('chat', { message: 'hi' }, 1);
    expect(useMonitoringStore.getState().eventFeed).toHaveLength(0);
  });

  it('resumes event feed when unpaused', () => {
    useMonitoringStore.getState().setEventFeedPaused(true);
    useMonitoringStore.getState().applyEvent('chat', { message: 'hi' }, 1);
    expect(useMonitoringStore.getState().eventFeed).toHaveLength(0);

    useMonitoringStore.getState().setEventFeedPaused(false);
    useMonitoringStore.getState().applyEvent('chat', { message: 'hello' }, 2);
    expect(useMonitoringStore.getState().eventFeed).toHaveLength(1);
  });
});

// ============================================================================
// 21. applyHelloOk via store action
// ============================================================================

describe('applyHelloOk store action', () => {
  beforeEach(() => {
    useMonitoringStore.getState().resetMonitoring();
  });

  it('updates instance via store action', () => {
    useMonitoringStore.getState().applyHelloOk({
      server: { version: '3.0.0', nodeId: 'node-xyz', uptimeMs: 9999 },
      features: { monitoring: true },
    });
    const state = useMonitoringStore.getState();
    expect(state.instance.version).toBe('3.0.0');
    expect(state.instance.nodeId).toBe('node-xyz');
    expect(state.instance.status).toBe('healthy');
  });
});

// ============================================================================
// 22. setSelectedRun
// ============================================================================

describe('setSelectedRun store action', () => {
  beforeEach(() => {
    useMonitoringStore.getState().resetMonitoring();
  });

  it('updates ui.selectedRunId', () => {
    useMonitoringStore.getState().setSelectedRun('run-selected');
    expect(useMonitoringStore.getState().ui.selectedRunId).toBe('run-selected');
  });

  it('can clear selected run', () => {
    useMonitoringStore.getState().setSelectedRun('run-x');
    useMonitoringStore.getState().setSelectedRun(null);
    expect(useMonitoringStore.getState().ui.selectedRunId).toBeNull();
  });
});

// ============================================================================
// 23. Multiple runs - ordering in recent
// ============================================================================

describe('recent runs ordering', () => {
  it('most recently completed run is at the front of recent array', () => {
    let state = makeInitialState();
    state = applyEvent(state, 'agent', { type: 'started', run_id: 'run-first' }, 1);
    state = applyEvent(state, 'agent', { type: 'started', run_id: 'run-second' }, 2);
    state = applyEvent(state, 'agent', { type: 'completed', run_id: 'run-first', ok: true }, 3);
    state = applyEvent(state, 'agent', { type: 'completed', run_id: 'run-second', ok: true }, 4);

    expect(state.runs.recent[0].runId).toBe('run-second');
    expect(state.runs.recent[1].runId).toBe('run-first');
  });
});

// ============================================================================
// 24. Feed event id uniqueness
// ============================================================================

describe('Feed event IDs are unique', () => {
  it('each event gets a unique id', () => {
    let state = makeInitialState();
    for (let i = 0; i < 10; i++) {
      state = applyEvent(state, 'chat', { msg: i }, i);
    }
    const ids = state.eventFeed.map((e) => e.id);
    const uniqueIds = new Set(ids);
    expect(uniqueIds.size).toBe(10);
  });
});

// ============================================================================
// 25. applySnapshot
// ============================================================================

describe('applySnapshot store action', () => {
  beforeEach(() => {
    useMonitoringStore.getState().resetMonitoring();
  });

  it('applies session data from snapshot', () => {
    useMonitoringStore.getState().applySnapshot({
      sessions: [
        { session_key: 'snap-sess-1', active: true },
        { session_key: 'snap-sess-2', active: false },
      ],
    });
    const state = useMonitoringStore.getState();
    expect(state.sessions.active['snap-sess-1']).toBeDefined();
    expect(state.sessions.active['snap-sess-2']).toBeDefined();
  });

  it('applies health data from snapshot', () => {
    useMonitoringStore.getState().applySnapshot({
      health: { status: 'degraded', active_runs: 5, queued_runs: 2 },
    });
    const state = useMonitoringStore.getState();
    expect(state.instance.status).toBe('degraded');
    expect(state.instance.activeRuns).toBe(5);
    expect(state.instance.queuedRuns).toBe(2);
  });
});
