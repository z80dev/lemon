import { create } from 'zustand';
import type {
  InstanceHealth,
  MonitoringAgent,
  MonitoringSession,
  MonitoringRun,
  MonitoringTask,
  MonitoringCronJob,
  MonitoringCronRun,
  MonitoringCronStatus,
  FeedEvent,
  MonitoringUIState,
  MonitoringUIFilters,
  SessionDetail,
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
  applyAgentsList as reducerApplyAgentsList,
  applyCronStatus as reducerApplyCronStatus,
  applyCronList as reducerApplyCronList,
  applyCronRuns as reducerApplyCronRuns,
} from './monitoringReducers';

export type { MonitoringUIFilters };

export interface MonitoringState {
  instance: InstanceHealth;
  agents: Record<string, MonitoringAgent>;   // keyed by agentId
  sessions: {
    active: Record<string, MonitoringSession>;   // keyed by sessionKey
    historical: MonitoringSession[];             // sorted by updatedAtMs desc
    selectedSessionKey: string | null;
    loadedSessionKeys: Set<string>;
  };
  sessionDetails: Record<string, SessionDetail>;  // keyed by sessionKey
  runs: {
    active: Record<string, MonitoringRun>;
    recent: MonitoringRun[];
  };
  tasks: {
    active: Record<string, MonitoringTask>;
    recent: MonitoringTask[];
  };
  cron: {
    status: MonitoringCronStatus | null;
    jobs: MonitoringCronJob[];
    runsByJob: Record<string, MonitoringCronRun[]>;
    selectedJobId: string | null;
  };
  runIntrospection: Record<string, { events: unknown[]; runRecord?: unknown; loadedAtMs: number }>;
  eventFeed: FeedEvent[];
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
  applyCronStatus: (payload: unknown) => void;
  applyCronList: (payload: unknown) => void;
  applyCronRuns: (jobId: string, payload: unknown) => void;
  setSelectedCronJob: (jobId: string | null) => void;
  applyRunIntrospection: (runId: string, payload: { events: unknown[]; runRecord?: unknown }) => void;
  applyAgentsList: (agents: unknown[]) => void;
  applySessionDetail: (detail: SessionDetail) => void;
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
  sessionDetails: {} as Record<string, SessionDetail>,
  runs: {
    active: {} as Record<string, MonitoringRun>,
    recent: [] as MonitoringRun[],
  },
  tasks: {
    active: {} as Record<string, MonitoringTask>,
    recent: [] as MonitoringTask[],
  },
  cron: {
    status: null as MonitoringCronStatus | null,
    jobs: [] as MonitoringCronJob[],
    runsByJob: {} as Record<string, MonitoringCronRun[]>,
    selectedJobId: null as string | null,
  },
  runIntrospection: {} as Record<string, { events: unknown[]; runRecord?: unknown; loadedAtMs: number }>,
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

  applyCronStatus: (payload) =>
    set((state) => reducerApplyCronStatus(state, payload as MonitoringCronStatus)),

  applyCronList: (payload) =>
    set((state) => {
      const p = (payload ?? {}) as Record<string, unknown>;
      const jobs = Array.isArray(p['jobs']) ? (p['jobs'] as MonitoringCronJob[]) : [];
      return reducerApplyCronList(state, jobs);
    }),

  applyCronRuns: (jobId, payload) =>
    set((state) => {
      const p = (payload ?? {}) as Record<string, unknown>;
      const runs = Array.isArray(p['runs']) ? (p['runs'] as MonitoringCronRun[]) : [];
      return reducerApplyCronRuns(state, jobId, runs);
    }),

  setSelectedCronJob: (jobId) =>
    set((state) => ({
      cron: {
        ...state.cron,
        selectedJobId: jobId,
      },
    })),

  applyRunIntrospection: (runId, payload) =>
    set((state) => ({
      runIntrospection: {
        ...state.runIntrospection,
        [runId]: {
          events: payload.events,
          runRecord: payload.runRecord,
          loadedAtMs: Date.now(),
        },
      },
    })),

  applyAgentsList: (agents) =>
    set((state) => reducerApplyAgentsList(state, agents)),

  applySessionDetail: (detail) =>
    set((state) => ({
      sessionDetails: {
        ...state.sessionDetails,
        [detail.sessionKey]: detail,
      },
    })),

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
      sessions: {
        active: {},
        historical: [],
        selectedSessionKey: null,
        loadedSessionKeys: new Set<string>(),
      },
      sessionDetails: {},
      cron: {
        status: null,
        jobs: [],
        runsByJob: {},
        selectedJobId: null,
      },
      runIntrospection: {},
    }),
}));
