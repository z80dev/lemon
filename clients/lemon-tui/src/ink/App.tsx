/**
 * App — Root component: creates store + connection, provides context, renders layout.
 */

import React, { useEffect, useRef, useCallback } from 'react';
import { render, Box, Text } from 'ink';
import { AppProvider } from './context/AppContext.js';
import { ThemeProvider } from './context/ThemeContext.js';
import { AppLayout } from './AppLayout.js';
import { useConnectionEvents } from './hooks/useConnectionEvents.js';
import { AgentConnection, type AgentConnectionOptions } from '../agent-connection.js';
import { StateStore } from '../state.js';
import type { UIRequestMessage, RunningSessionInfo, SessionSummary } from '../types.js';

interface AppProps {
  options: AgentConnectionOptions;
  themeName?: string;
}

/**
 * Inner component that wires connection events.
 * Must be inside AppProvider.
 */
function AppInner({
  connection,
  store,
  options,
  onStop,
}: {
  connection: AgentConnection;
  store: StateStore;
  options: AgentConnectionOptions;
  onStop: () => void;
}) {
  const pendingAutoSwitch = useRef(false);

  // Handle connection events
  useConnectionEvents(connection, store, {
    onUIRequest: (request: UIRequestMessage) => {
      store.enqueueUIRequest(request);
    },
    onUINotify: () => {},
    onSessionsList: () => {},
    onSaveResult: (msg) => {
      if (msg.ok) {
        const message = msg.path ? `Saved session to ${msg.path}` : 'Session saved';
        // Notifications handled via store.setError for now (will show in ErrorBar)
      }
    },
    onSessionStarted: (msg) => {
      store.handleSessionStarted(msg.session_id, msg.cwd, msg.model);
      if (pendingAutoSwitch.current) {
        pendingAutoSwitch.current = false;
        connection.setActiveSession(msg.session_id);
      }
    },
    onSessionClosed: (msg) => {
      store.handleSessionClosed(msg.session_id, msg.reason);
    },
    onRunningSessions: (msg) => {
      if (!msg.error) {
        store.setRunningSessions(msg.sessions);
      }
    },
    onModelsList: () => {},
    onActiveSession: (msg) => {
      store.setActiveSessionId(msg.session_id);
      if (msg.session_id) {
        const session = store.getSession(msg.session_id);
        if (session) {
          store.setTitle(`Lemon - ${session.model.id} [${msg.session_id.slice(0, 8)}]`);
        }
      } else {
        store.setTitle('Lemon');
      }
    },
    onSetEditorText: () => {},
    onClose: (code) => {
      const restartCode = connection.getRestartExitCode();
      if (code === restartCode) {
        connection.restart().catch((err: Error) => {
          store.setError(`Failed to restart: ${err.message}`);
        });
        return;
      }
      store.setError(`Connection closed (code: ${code})`);
    },
    onReady: () => {
      // If session file was provided via CLI, start it
      if (options.sessionFile) {
        pendingAutoSwitch.current = true;
        connection.startSession({ sessionFile: options.sessionFile });
        options.sessionFile = undefined;
      }
    },
  });

  // SIGINT handling
  useEffect(() => {
    const handler = () => {
      if (store.getState().busy) {
        connection.abort();
      } else {
        onStop();
      }
    };
    process.on('SIGINT', handler);
    return () => {
      process.removeListener('SIGINT', handler);
    };
  }, [store, connection, onStop]);

  return <AppLayout onStop={onStop} />;
}

/**
 * Start the Ink-based Lemon TUI.
 */
export function startApp(options: AgentConnectionOptions, themeName?: string): void {
  const store = new StateStore({ cwd: options.cwd });
  const connection = new AgentConnection(options);

  if (options.debug) {
    store.setDebug(true);
  }

  let inkInstance: ReturnType<typeof render> | null = null;

  const stop = () => {
    connection.stop();
    if (inkInstance) {
      inkInstance.unmount();
    }
    process.exit(0);
  };

  process.stdout.write('Starting Lemon TUI...\n');

  connection.start().then(() => {
    inkInstance = render(
      <AppProvider store={store} connection={connection}>
        <ThemeProvider initialTheme={themeName}>
          <AppInner
            connection={connection}
            store={store}
            options={options}
            onStop={stop}
          />
        </ThemeProvider>
      </AppProvider>
    );
  }).catch((err: unknown) => {
    const message = err instanceof Error ? err.message : String(err);
    process.stderr.write(`Failed to start: ${message}\n`);
    process.exit(1);
  });
}
