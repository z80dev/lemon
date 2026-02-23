import { create } from 'zustand';
import type {
  InstanceHealth,
  MonitoringAgent,
  MonitoringSession,
  MonitoringRun,
  MonitoringTask,
  FeedEvent,
  MonitoringUIState,
  MonitoringUIFilters,
} from '../../../shared/src/monitoringTypes';
import {
  applyHelloOk as reducerApplyHelloOk,
  applyEvent as reducerApplyEvent,
  applyRunsActiveList as reducerApplyRunsActiveList,
  applyRunsRecentList as reducerApplyRunsRecentList,
  applySessionsActiveList as reducerApplySessionsActiveList,
  applySessionsList as reducerApplySessionsList,
  applyTasksActiveList as reducerApplyTasksActiveList,
  applyTasksRecentList as reducerApplyTasksRecentList,
  applySnapshot as reducerApplySnapshot,
} from './monitoringReducers';

export type { MonitoringUIFilters };

export interface MonitoringState {
  instance: InstanceHealth;
  agents: Record<string, MonitoringAgent>;   // keyed by agentId
  sessions: {
    active: Record<string, MonitoringSession>;   // keyed by sessionKey
    historical: MonitoringSession[];             // sorted by updatedAtMs desc
    selectedSessionKey: string | null;
    loadedSessionKeys: Set<string>;             // sessions with chat history loaded
  };
  runs: {
    active: Record<string, MonitoringRun>;  // keyed by runId
    recent: MonitoringRun[];               // sorted by completedAtMs desc, max 200
  };
  tasks: {
    active: Record<string, MonitoringTask>; // keyed by taskId
    recent: MonitoringTask[];              // sorted by completedAtMs desc, max 200
  };
  eventFeed: FeedEvent[];                   // capped at MAX_FEED_EVENTS
  ui: MonitoringUIState;

  // Actions
  applyHelloOk: (frame: { server: unknown; features: unknown; snapshot?: unknown }) => void;
  applyEvent: (eventName: string, payload: unknown, seq: number) => void;
  applyRunsActiveList: (payload: unknown) => void;
  applyRunsRecentList: (payload: unknown) => void;
  applySessionsActiveList: (sessions: unknown[]) => void;
  applySessionsList: (sessions: unknown[]) => void;
  applyTasksActiveList: (tasks: unknown[]) => void;
  applyTasksRecentList: (tasks: unknown[]) => void;
  applySnapshot: (snapshot: unknown) => void;
  setSelectedSession: (sessionKey: string | null) => void;
  setSelectedRun: (runId: string | null) => void;
  setUIFilter: (key: keyof MonitoringUIFilters, value: unknown) => void;
  setEventFeedPaused: (paused: boolean) => void;
  clearEventFeed: () => void;
  resetMonitoring: () => void;
}

export const INITIAL_INSTANCE: InstanceHealth = {
  status: 'unknown',
  uptimeMs: null,
  connectedClients: 0,
  activeRuns: 0,
  queuedRuns: 0,
  completedToday: 0,
  nodeId: null,
  version: null,
  lastUpdatedMs: null,
};

export const INITIAL_UI: MonitoringUIState = {
  selectedSessionKey: null,
  selectedRunId: null,
  selectedTaskId: null,
  filters: {
    agentId: null,
    sessionKey: null,
    runId: null,
    status: null,
    timeRangeMs: null,
    eventTypes: [],
  },
  eventFeedPaused: false,
  sidebarTab: 'sessions',
};

const INITIAL_STATE = {
  instance: INITIAL_INSTANCE,
  agents: {} as Record<string, MonitoringAgent>,
  sessions: {
    active: {} as Record<string, MonitoringSession>,
    historical: [] as MonitoringSession[],
    selectedSessionKey: null,
    loadedSessionKeys: new Set<string>(),
  },
  runs: {
    active: {} as Record<string, MonitoringRun>,
    recent: [] as MonitoringRun[],
  },
  tasks: {
    active: {} as Record<string, MonitoringTask>,
    recent: [] as MonitoringTask[],
  },
  eventFeed: [] as FeedEvent[],
  ui: INITIAL_UI,
};

export const useMonitoringStore = create<MonitoringState>((set) => ({
  ...INITIAL_STATE,

  applyHelloOk: (frame) =>
    set((state) =>
      reducerApplyHelloOk(state, {
        server: (frame.server ?? {}) as { version?: string; nodeId?: string; uptimeMs?: number },
        features: (frame.features ?? {}) as Record<string, boolean>,
        snapshot: frame.snapshot as Record<string, unknown> | undefined,
      })
    ),

  applyEvent: (eventName, payload, seq) =>
    set((state) => reducerApplyEvent(state, eventName, payload, seq)),

  applyRunsActiveList: (payload) =>
    set((state) => {
      const p = (payload ?? {}) as Record<string, unknown>;
      const runs = Array.isArray(p['runs']) ? (p['runs'] as MonitoringRun[]) : [];
      const total = typeof p['total'] === 'number' ? p['total'] : runs.length;
      return reducerApplyRunsActiveList(state, { runs, total });
    }),

  applyRunsRecentList: (payload) =>
    set((state) => {
      const p = (payload ?? {}) as Record<string, unknown>;
      const runs = Array.isArray(p['runs']) ? (p['runs'] as MonitoringRun[]) : [];
      const total = typeof p['total'] === 'number' ? p['total'] : runs.length;
      return reducerApplyRunsRecentList(state, { runs, total });
    }),

  applySessionsActiveList: (sessions) =>
    set((state) => reducerApplySessionsActiveList(state, sessions)),

  applySessionsList: (sessions) =>
    set((state) => reducerApplySessionsList(state, sessions)),

  applyTasksActiveList: (tasks) =>
    set((state) => reducerApplyTasksActiveList(state, tasks as MonitoringTask[])),

  applyTasksRecentList: (tasks) =>
    set((state) => reducerApplyTasksRecentList(state, tasks as MonitoringTask[])),

  applySnapshot: (snapshot) =>
    set((state) =>
      reducerApplySnapshot(state, (snapshot ?? {}) as Record<string, unknown>)
    ),

  setSelectedSession: (sessionKey) =>
    set((state) => ({
      ui: {
        ...state.ui,
        selectedSessionKey: sessionKey,
      },
      sessions: {
        ...state.sessions,
        selectedSessionKey: sessionKey,
      },
    })),

  setSelectedRun: (runId) =>
    set((state) => ({
      ui: {
        ...state.ui,
        selectedRunId: runId,
      },
    })),

  setUIFilter: (key, value) =>
    set((state) => ({
      ui: {
        ...state.ui,
        filters: {
          ...state.ui.filters,
          [key]: value,
        },
      },
    })),

  setEventFeedPaused: (paused) =>
    set((state) => ({
      ui: { ...state.ui, eventFeedPaused: paused },
    })),

  clearEventFeed: () => set({ eventFeed: [] }),

  resetMonitoring: () =>
    set({
      ...INITIAL_STATE,
      // Re-create new Set and fresh objects to avoid reference sharing
      sessions: {
        active: {},
        historical: [],
        selectedSessionKey: null,
        loadedSessionKeys: new Set<string>(),
      },
    }),
}));
