/**
 * Slash command handler hook.
 */

import { useCallback } from 'react';
import { useStore, useConnection } from '../context/AppContext.js';

interface CommandHandlers {
  onShowSettings: () => void;
  onShowHelp: () => void;
  onShowStats: () => void;
  onShowSearch: (query: string) => void;
  onShowNotifications: () => void;
  onNewSession: (opts?: { cwd?: string; model?: string }) => void;
  onShowRunning: () => void;
  onStop: () => void;
  onRestart: (reason: string) => void;
  onClearMessages: () => void;
  onNotify: (message: string, type?: string) => void;
  onEditLastMessage: () => void;
  onCopyLastCode: () => void;
}

interface GoalCommandOptions {
  maxContinuations?: number;
  maxTicks?: number;
  intervalMs?: number;
  waitTimeoutMs?: number;
  judgeModel?: string;
  judgeFailurePolicy?: string;
  model?: string;
  auto?: boolean;
}

interface ParsedGoalArgs {
  rest: string[];
  options: GoalCommandOptions;
  error?: string;
}

interface KanbanCommandOptions {
  status?: string;
  owner?: string;
  workspace?: string;
  priority?: string;
  assignee?: string;
  workerProfile?: string;
  sessionKey?: string;
  runId?: string;
  author?: string;
  limit?: number;
  intervalMs?: number;
  maxConcurrency?: number;
  leaseMs?: number;
  workerId?: string;
}

interface ParsedKanbanArgs {
  rest: string[];
  options: KanbanCommandOptions;
  error?: string;
}

export function useCommands(handlers: CommandHandlers) {
  const store = useStore();
  const connection = useConnection();

  const handleCommand = useCallback(
    (cmd: string, args: string[]) => {
      switch (cmd.toLowerCase()) {
        case 'abort':
          connection.abort();
          break;

        case 'reset':
          connection.reset();
          store.resetActiveSession();
          handlers.onClearMessages();
          break;

        case 'save':
          connection.save();
          break;

        case 'sessions':
          connection.listSessions();
          break;

        case 'resume':
          if (args.length > 0) {
            // Direct resume handled at app level
          }
          connection.listSessions();
          break;

        case 'stats':
          handlers.onShowStats();
          break;

        case 'search':
          handlers.onShowSearch(args.join(' '));
          break;

        case 'settings':
          handlers.onShowSettings();
          break;

        case 'debug': {
          const arg = args[0]?.toLowerCase();
          const state = store.getState();
          let newDebug: boolean;
          if (arg === 'on') newDebug = true;
          else if (arg === 'off') newDebug = false;
          else newDebug = !state.debug;
          store.setDebug(newDebug);
          handlers.onNotify(`Debug mode ${newDebug ? 'enabled' : 'disabled'}`, 'info');
          break;
        }

        case 'restart':
          handlers.onRestart(args.join(' ') || 'User requested restart');
          break;

        case 'goal': {
          const action = args[0]?.toLowerCase() || 'status';
          const state = store.getState();
          const sessionId = state.activeSessionId || undefined;
          const goalUsage =
            'Usage: /goal [status|set [--max-continuations N] <objective>|pause|resume|continue [--max-continuations N] [--model MODEL]|loop once [--judge-model MODEL] [--judge-failure-policy pause|continueOnce|needsInput]|loop start [--auto] [--max-ticks N] [--max-continuations N] [--interval-ms N] [--wait-timeout-ms N] [--judge-model MODEL] [--judge-failure-policy pause|continueOnce|needsInput]|loop stop|loop status|clear]';

          if (action === 'status') {
            connection.goalStatus(sessionId);
          } else if (action === 'set') {
            const parsed = parseGoalCommandOptions(args.slice(1));
            if (parsed.error) {
              store.setError(parsed.error);
              break;
            }
            const objective = parsed.rest.join(' ').trim();
            if (objective) {
              connection.goalSet(objective, sessionId, parsed.options);
            } else {
              store.setError('Usage: /goal set [--max-continuations N] <objective>');
            }
          } else if (action === 'pause') {
            connection.goalPause(sessionId);
          } else if (action === 'resume') {
            connection.goalResume(sessionId);
          } else if (action === 'continue') {
            const parsed = parseGoalCommandOptions(args.slice(1));
            if (parsed.error) {
              store.setError(parsed.error);
              break;
            }
            connection.goalContinue(sessionId, parsed.options);
          } else if (action === 'loop' && args[1]?.toLowerCase() === 'once') {
            const parsed = parseGoalCommandOptions(args.slice(2));
            if (parsed.error) {
              store.setError(parsed.error);
              break;
            }
            connection.goalLoopOnce(sessionId, parsed.options);
          } else if (action === 'loop' && args[1]?.toLowerCase() === 'start') {
            const parsed = parseGoalCommandOptions(args.slice(2));
            if (parsed.error) {
              store.setError(parsed.error);
              break;
            }
            connection.goalLoopStart(sessionId, parsed.options);
          } else if (action === 'loop' && args[1]?.toLowerCase() === 'stop') {
            connection.goalLoopStop(sessionId);
          } else if (action === 'loop' && args[1]?.toLowerCase() === 'status') {
            connection.goalLoopStatus(sessionId);
          } else if (action === 'clear') {
            connection.goalClear(sessionId);
          } else {
            store.setError(goalUsage);
          }
          break;
        }

        case 'kanban': {
          const action = args[0]?.toLowerCase() || 'boards';
          const kanbanUsage =
            'Usage: /kanban [boards|create <name>|show <board-id>|archive <board-id>|task create <board-id> <title>|task update <task-id> [--status STATUS] [--priority PRIORITY]|comment <task-id> <body>|dispatch start|status|stop <board-id>]';

          if (action === 'boards' || action === 'list') {
            const parsed = parseKanbanCommandOptions(args.slice(1));
            if (parsed.error) {
              store.setError(parsed.error);
              break;
            }
            connection.kanbanBoardList(parsed.options);
          } else if (action === 'create') {
            const parsed = parseKanbanCommandOptions(args.slice(1));
            if (parsed.error) {
              store.setError(parsed.error);
              break;
            }
            const name = parsed.rest.join(' ').trim();
            if (name) {
              connection.kanbanBoardCreate(name, parsed.options);
            } else {
              store.setError('Usage: /kanban create <name>');
            }
          } else if (action === 'show' || action === 'get' || action === 'tasks') {
            const parsed = parseKanbanCommandOptions(args.slice(1));
            if (parsed.error) {
              store.setError(parsed.error);
              break;
            }
            const boardId = parsed.rest[0];
            if (boardId) {
              connection.kanbanBoardGet(boardId, parsed.options);
            } else {
              store.setError('Usage: /kanban show <board-id>');
            }
          } else if (action === 'archive') {
            const parsed = parseKanbanCommandOptions(args.slice(1));
            if (parsed.error) {
              store.setError(parsed.error);
              break;
            }
            const boardId = parsed.rest[0];
            if (boardId) {
              connection.kanbanBoardArchive(boardId);
            } else {
              store.setError('Usage: /kanban archive <board-id>');
            }
          } else if (action === 'task' && args[1]?.toLowerCase() === 'create') {
            const parsed = parseKanbanCommandOptions(args.slice(2));
            if (parsed.error) {
              store.setError(parsed.error);
              break;
            }
            const [boardId, ...titleParts] = parsed.rest;
            const title = titleParts.join(' ').trim();
            if (boardId && title) {
              connection.kanbanTaskCreate(boardId, title, parsed.options);
            } else {
              store.setError('Usage: /kanban task create <board-id> <title>');
            }
          } else if (action === 'task' && args[1]?.toLowerCase() === 'update') {
            const parsed = parseKanbanCommandOptions(args.slice(2));
            if (parsed.error) {
              store.setError(parsed.error);
              break;
            }
            const taskId = parsed.rest[0];
            if (taskId) {
              connection.kanbanTaskUpdate(taskId, parsed.options);
            } else {
              store.setError('Usage: /kanban task update <task-id> [--status STATUS]');
            }
          } else if (action === 'comment') {
            const parsed = parseKanbanCommandOptions(args.slice(1));
            if (parsed.error) {
              store.setError(parsed.error);
              break;
            }
            const [taskId, ...bodyParts] = parsed.rest;
            const body = bodyParts.join(' ').trim();
            if (taskId && body) {
              connection.kanbanTaskComment(taskId, body, parsed.options);
            } else {
              store.setError('Usage: /kanban comment <task-id> <body>');
            }
          } else if (action === 'dispatch') {
            const dispatchAction = args[1]?.toLowerCase();
            const parsed = parseKanbanCommandOptions(args.slice(2));
            if (parsed.error) {
              store.setError(parsed.error);
              break;
            }
            const boardId = parsed.rest[0];
            if (!boardId) {
              store.setError('Usage: /kanban dispatch start|status|stop <board-id>');
              break;
            }
            if (dispatchAction === 'start') {
              connection.kanbanDispatcherStart(boardId, parsed.options);
            } else if (dispatchAction === 'status') {
              connection.kanbanDispatcherStatus(boardId);
            } else if (dispatchAction === 'stop') {
              connection.kanbanDispatcherStop(boardId);
            } else {
              store.setError('Usage: /kanban dispatch start|status|stop <board-id>');
            }
          } else {
            store.setError(kanbanUsage);
          }
          break;
        }

        case 'checkpoint': {
          const action = args[0]?.toLowerCase() || 'diff';
          const checkpointUsage =
            'Usage: /checkpoint [diff|restore] <checkpoint-id> [path ...]';

          if (action === 'diff' || action === 'restore') {
            const checkpointId = args[1];
            const paths = args.slice(2);

            if (!checkpointId) {
              store.setError(checkpointUsage);
              break;
            }

            if (action === 'diff') {
              connection.checkpointDiff(checkpointId, paths);
            } else {
              connection.checkpointRestore(checkpointId, paths);
            }
          } else {
            store.setError(checkpointUsage);
          }
          break;
        }

        case 'cron': {
          const action = args[0]?.toLowerCase();
          const cronUsage = 'Usage: /cron abort <run-id>';

          if (action === 'abort') {
            const runId = args[1];
            if (runId) {
              connection.cronAbort(runId);
            } else {
              store.setError(cronUsage);
            }
          } else {
            store.setError(cronUsage);
          }
          break;
        }

        case 'approval': {
          const action = args[0]?.toLowerCase();
          const approvalId = args[1];
          const approvalUsage =
            'Usage: /approval [list|approve|once|session|agent|global|deny <approval-id>]';
          const decision = mapApprovalDecision(action);

          if (!action || action === 'list' || action === 'status' || action === 'pending') {
            connection.approvalList();
          } else if (decision && approvalId) {
            connection.approvalResolve(approvalId, decision);
          } else {
            store.setError(approvalUsage);
          }
          break;
        }

        case 'quit':
        case 'exit':
        case 'q':
          handlers.onStop();
          break;

        case 'help':
          handlers.onShowHelp();
          break;

        case 'compact':
          store.toggleCompactMode();
          handlers.onNotify(
            `Compact mode ${store.getState().compactMode ? 'enabled' : 'disabled'}`,
            'info'
          );
          break;

        case 'bell':
          store.toggleBell();
          handlers.onNotify(
            `Terminal bell ${store.getState().bellEnabled ? 'enabled' : 'disabled'}`,
            'info'
          );
          break;

        case 'notifications':
          handlers.onShowNotifications();
          break;

        case 'running':
          handlers.onShowRunning();
          break;

        case 'new-session': {
          const opts: { cwd?: string; model?: string } = {};
          for (let i = 0; i < args.length; i++) {
            if (args[i] === '--cwd' && args[i + 1]) opts.cwd = args[++i];
            else if (args[i] === '--model' && args[i + 1]) opts.model = args[++i];
          }
          handlers.onNewSession(opts);
          break;
        }

        case 'switch':
          if (args.length > 0) {
            connection.setActiveSession(args[0]);
          } else {
            connection.listRunningSessions();
          }
          break;

        case 'close-session': {
          const state = store.getState();
          const sessionToClose = args[0] || state.activeSessionId;
          if (sessionToClose) {
            connection.closeSession(sessionToClose);
          } else {
            store.setError('No session to close');
          }
          break;
        }

        case 'edit':
          handlers.onEditLastMessage();
          break;

        case 'copy':
          handlers.onCopyLastCode();
          break;

        default:
          store.setError(`Unknown command: /${cmd}`);
      }
    },
    [connection, store, handlers]
  );

  const handleInput = useCallback(
    (text: string) => {
      const trimmed = text.trim();
      if (!trimmed) return;

      if (trimmed.startsWith('/')) {
        const [cmd, ...args] = trimmed.slice(1).split(/\s+/);
        handleCommand(cmd, args);
        return;
      }

      const activeSessionId = store.getState().activeSessionId;
      if (!activeSessionId) {
        handlers.onNewSession();
        return;
      }
      connection.prompt(trimmed, activeSessionId);
    },
    [handleCommand, store, connection, handlers]
  );

  return { handleInput, handleCommand };
}

function mapApprovalDecision(action: string | undefined) {
  switch (action) {
    case 'approve':
    case 'once':
      return 'approve_once';
    case 'session':
      return 'approve_session';
    case 'agent':
      return 'approve_agent';
    case 'global':
      return 'approve_global';
    case 'deny':
      return 'deny';
    default:
      return null;
  }
}

function parseGoalCommandOptions(args: string[]): ParsedGoalArgs {
  const rest: string[] = [];
  const options: GoalCommandOptions = {};

  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    const [flag, inlineValue] = arg.includes('=') ? arg.split(/=(.*)/s, 2) : [arg, undefined];
    const normalized = flag.toLowerCase();

    if (!normalized.startsWith('--')) {
      rest.push(arg);
      continue;
    }

    if (normalized === '--auto') {
      options.auto = true;
      continue;
    }

    const value = inlineValue ?? args[i + 1];
    if (inlineValue === undefined) {
      i += 1;
    }

    if (value === undefined || value.trim() === '') {
      return { rest, options, error: `${flag} requires a value.` };
    }

    switch (normalized) {
      case '--max-continuations':
      case '--max':
      case '--budget': {
        const parsed = parseNonNegativeInteger(value);
        if (parsed === null) return { rest, options, error: `${flag} must be a non-negative integer.` };
        options.maxContinuations = parsed;
        break;
      }
      case '--max-ticks': {
        const parsed = parsePositiveInteger(value);
        if (parsed === null) return { rest, options, error: `${flag} must be a positive integer.` };
        options.maxTicks = parsed;
        break;
      }
      case '--interval-ms': {
        const parsed = parseNonNegativeInteger(value);
        if (parsed === null) return { rest, options, error: `${flag} must be a non-negative integer.` };
        options.intervalMs = parsed;
        break;
      }
      case '--wait-timeout-ms': {
        const parsed = parsePositiveInteger(value);
        if (parsed === null) return { rest, options, error: `${flag} must be a positive integer.` };
        options.waitTimeoutMs = parsed;
        break;
      }
      case '--judge-model':
        options.judgeModel = value;
        break;
      case '--judge-failure-policy':
        options.judgeFailurePolicy = value;
        break;
      case '--model':
        options.model = value;
        break;
      default:
        return { rest, options, error: `Unknown goal option: ${flag}` };
    }
  }

  return { rest, options };
}

function parseKanbanCommandOptions(args: string[]): ParsedKanbanArgs {
  const rest: string[] = [];
  const options: KanbanCommandOptions = {};

  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    const [flag, inlineValue] = arg.includes('=') ? arg.split(/=(.*)/s, 2) : [arg, undefined];
    const normalized = flag.toLowerCase();

    if (!normalized.startsWith('--')) {
      rest.push(arg);
      continue;
    }

    const value = inlineValue ?? args[i + 1];
    if (inlineValue === undefined) {
      i += 1;
    }

    if (value === undefined || value.trim() === '') {
      return { rest, options, error: `${flag} requires a value.` };
    }

    switch (normalized) {
      case '--status':
        options.status = value;
        break;
      case '--owner':
        options.owner = value;
        break;
      case '--workspace':
        options.workspace = value;
        break;
      case '--priority':
        options.priority = value;
        break;
      case '--assignee':
        options.assignee = value;
        break;
      case '--worker-profile':
        options.workerProfile = value;
        break;
      case '--session-key':
        options.sessionKey = value;
        break;
      case '--run-id':
        options.runId = value;
        break;
      case '--author':
        options.author = value;
        break;
      case '--worker-id':
        options.workerId = value;
        break;
      case '--limit': {
        const parsed = parsePositiveInteger(value);
        if (parsed === null) return { rest, options, error: `${flag} must be a positive integer.` };
        options.limit = parsed;
        break;
      }
      case '--interval-ms': {
        const parsed = parsePositiveInteger(value);
        if (parsed === null) return { rest, options, error: `${flag} must be a positive integer.` };
        options.intervalMs = parsed;
        break;
      }
      case '--max-concurrency': {
        const parsed = parsePositiveInteger(value);
        if (parsed === null) return { rest, options, error: `${flag} must be a positive integer.` };
        options.maxConcurrency = parsed;
        break;
      }
      case '--lease-ms': {
        const parsed = parsePositiveInteger(value);
        if (parsed === null) return { rest, options, error: `${flag} must be a positive integer.` };
        options.leaseMs = parsed;
        break;
      }
      default:
        return { rest, options, error: `Unknown kanban option: ${flag}` };
    }
  }

  return { rest, options };
}

function parseNonNegativeInteger(value: string): number | null {
  if (!/^\d+$/.test(value)) return null;
  return Number(value);
}

function parsePositiveInteger(value: string): number | null {
  const parsed = parseNonNegativeInteger(value);
  return parsed !== null && parsed > 0 ? parsed : null;
}
