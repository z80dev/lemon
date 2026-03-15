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
