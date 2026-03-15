/**
 * AppLayout — vertical layout of all UI sections.
 * Conditionally renders sections based on app state.
 */

import { execSync } from 'node:child_process';
import React, { useState, useRef, useCallback, useEffect } from 'react';
import { Box, Text, useInput } from 'ink';
import { useStore, useConnection } from './context/AppContext.js';
import { useTheme } from './context/ThemeContext.js';
import { useAppSelector } from './hooks/useAppState.js';
import { useGitModeline } from './hooks/useGitModeline.js';
import { useCommands } from './hooks/useCommands.js';
import { CombinedAutocompleteProvider } from '../autocomplete.js';
import { slashCommands } from '../constants.js';
import type { UIRequestMessage, SelectParams, ConfirmParams, InputParams, EditorParams } from '../types.js';

// Components
import { Header } from './components/Header.js';
import { WelcomeScreen } from './components/WelcomeScreen.js';
import { StatusBar } from './components/StatusBar.js';
import { Modeline } from './components/Modeline.js';
import { ToolExecutionBar } from './components/ToolExecutionBar.js';
import { ToolPanel } from './components/ToolPanel.js';
import { ToolHint } from './components/ToolHint.js';
import { WidgetPanel } from './components/WidgetPanel.js';
import { ErrorBar } from './components/ErrorBar.js';
import { Loader } from './components/Loader.js';
import { MessageList } from './components/MessageList.js';
import { InputEditor, type InputEditorHandle } from './components/InputEditor.js';

// Overlays
import { SelectOverlay } from './components/SelectOverlay.js';
import { ConfirmOverlay } from './components/ConfirmOverlay.js';
import { InputOverlay } from './components/InputOverlay.js';
import { EditorOverlay } from './components/EditorOverlay.js';
import { SettingsOverlay } from './components/SettingsOverlay.js';
import { HelpOverlay } from './components/HelpOverlay.js';
import { StatsOverlay } from './components/StatsOverlay.js';
import { SearchOverlay } from './components/SearchOverlay.js';
import { ErrorBoundary } from './components/ErrorBoundary.js';
import { NotificationHistoryOverlay } from './components/NotificationHistoryOverlay.js';
import { SessionPickerOverlay } from './components/SessionPickerOverlay.js';

interface Notification {
  id: number;
  message: string;
  type: string;
}

type OverlayState =
  | null
  | { kind: 'select'; request: UIRequestMessage }
  | { kind: 'confirm'; request: UIRequestMessage }
  | { kind: 'input'; request: UIRequestMessage }
  | { kind: 'editor'; request: UIRequestMessage }
  | { kind: 'settings' }
  | { kind: 'help' }
  | { kind: 'stats' }
  | { kind: 'search'; query: string }
  | { kind: 'notifications' }
  | {
      kind: 'local-select';
      title: string;
      options: Array<{ label: string; value: string; description?: string }>;
      onSelect: (value: string) => void;
    }
  | { kind: 'local-input'; title: string; placeholder?: string; onSubmit: (value: string) => void }
  | { kind: 'session-picker' };

export function AppLayout({ onStop }: { onStop: () => void }) {
  const store = useStore();
  const connection = useConnection();
  const theme = useTheme();

  const messages = useAppSelector((s) => s.messages);
  const ready = useAppSelector((s) => s.ready);
  const busy = useAppSelector((s) => s.busy);
  const activeSessionId = useAppSelector((s) => s.activeSessionId);
  const sessions = useAppSelector((s) => s.sessions);
  const cwd = useAppSelector((s) => s.cwd);
  const title = useAppSelector((s) => s.title);
  const bellEnabled = useAppSelector((s) => s.bellEnabled);

  const [toolPanelCollapsed, setToolPanelCollapsed] = useState(false);
  const [overlay, setOverlay] = useState<OverlayState>(null);
  const [notifications, setNotifications] = useState<Notification[]>([]);
  const [welcomeVisible, setWelcomeVisible] = useState(true);
  const notifIdRef = useRef(0);
  const editorRef = useRef<InputEditorHandle>(null);
  const pendingAutoSwitch = useRef(false);
  const prevBusyRef = useRef(false);

  // Autocomplete provider
  const autocompleteProvider = React.useMemo(
    () => new CombinedAutocompleteProvider(slashCommands, cwd || process.cwd()),
    [cwd]
  );

  // Set terminal title
  useEffect(() => {
    process.stdout.write(`\x1b]0;${title}\x07`);
  }, [title]);

  // Hide welcome when messages arrive
  useEffect(() => {
    if (messages.length > 0 && welcomeVisible) {
      setWelcomeVisible(false);
    }
  }, [messages.length, welcomeVisible]);

  // Terminal bell on agent completion (busy → idle transition)
  useEffect(() => {
    if (prevBusyRef.current && !busy && bellEnabled) {
      process.stdout.write('\x07');
    }
    prevBusyRef.current = busy;
  }, [busy, bellEnabled]);

  // Git modeline
  useGitModeline();

  // Notification helper
  const addNotification = useCallback((message: string, type: string = 'info') => {
    const id = ++notifIdRef.current;
    setNotifications((prev) => [...prev, { id, message, type }]);
    store.addNotification(message, type);
    setTimeout(() => {
      setNotifications((prev) => prev.filter((n) => n.id !== id));
    }, 5000);
  }, [store]);

  // UI request handler
  const handleUIRequest = useCallback((request: UIRequestMessage) => {
    store.enqueueUIRequest(request);
    // Check if we should show it immediately
    const current = store.getCurrentUIRequest();
    if (current && !overlay) {
      showUIOverlay(current);
    }
  }, [store, overlay]);

  const showUIOverlay = useCallback((request: UIRequestMessage) => {
    switch (request.method) {
      case 'select':
        setOverlay({ kind: 'select', request });
        break;
      case 'confirm':
        setOverlay({ kind: 'confirm', request });
        break;
      case 'input':
        setOverlay({ kind: 'input', request });
        break;
      case 'editor':
        setOverlay({ kind: 'editor', request });
        break;
    }
  }, []);

  const dismissOverlay = useCallback((requestId?: string, result?: unknown, error?: string | null) => {
    if (requestId) {
      connection.respondToUIRequest(requestId, result, error ?? null);
      store.dequeueUIRequest();
    }
    setOverlay(null);

    // Show next queued request
    setTimeout(() => {
      const next = store.getCurrentUIRequest();
      if (next) {
        showUIOverlay(next);
      }
    }, 0);
  }, [connection, store, showUIOverlay]);

  // Command handlers
  const { handleInput } = useCommands({
    onShowSettings: () => setOverlay({ kind: 'settings' }),
    onShowHelp: () => setOverlay({ kind: 'help' }),
    onShowStats: () => setOverlay({ kind: 'stats' }),
    onShowSearch: (query) => setOverlay({ kind: 'search', query }),
    onShowNotifications: () => setOverlay({ kind: 'notifications' }),
    onNewSession: (opts) => {
      // Show local input overlay for cwd
      const defaultCwd = opts?.cwd ?? cwd ?? '';
      setOverlay({
        kind: 'local-input',
        title: 'New session: working directory',
        placeholder: defaultCwd,
        onSubmit: (cwdValue) => {
          if (!cwdValue) { setOverlay(null); return; }
          if (opts?.model) {
            pendingAutoSwitch.current = true;
            connection.startSession({ cwd: cwdValue, model: opts.model });
            setOverlay(null);
          } else {
            // Ask for model
            setOverlay({
              kind: 'local-input',
              title: 'Model (provider:model_id, or empty for default)',
              placeholder: '',
              onSubmit: (modelSpec) => {
                pendingAutoSwitch.current = true;
                connection.startSession({
                  cwd: cwdValue,
                  model: modelSpec || undefined,
                });
                setOverlay(null);
              },
            });
          }
        },
      });
    },
    onShowRunning: () => {
      connection.listRunningSessions();
    },
    onStop,
    onRestart: async (reason) => {
      addNotification(`Restarting agent: ${reason}`, 'warning');
      store.reset();
      try {
        await connection.restart();
        addNotification('Agent restarted', 'success');
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        store.setError(`Failed to restart agent: ${msg}`);
      }
    },
    onClearMessages: () => {
      // Messages are derived from store, reset clears them
    },
    onNotify: addNotification,
    onEditLastMessage: () => {
      for (let i = messages.length - 1; i >= 0; i--) {
        const msg = messages[i];
        if (msg.type === 'user') {
          editorRef.current?.setText(msg.content);
          return;
        }
      }
      addNotification('No user message to edit', 'warning');
    },
    onCopyLastCode: () => {
      try {
        for (let i = messages.length - 1; i >= 0; i--) {
          const msg = messages[i];
          if (msg.type === 'assistant') {
            const text = (msg as any).textContent as string;
            const match = text.match(/```[^\n]*\n([\s\S]*?)```/);
            if (match) {
              const code = match[1];
              const cmd = process.platform === 'darwin' ? 'pbcopy' : 'xclip -selection clipboard';
              execSync(cmd, { input: code });
              addNotification('Code copied to clipboard', 'success');
              return;
            }
          }
        }
        addNotification('No code block found', 'warning');
      } catch (err) {
        const errMsg = err instanceof Error ? err.message : String(err);
        addNotification(`Failed to copy: ${errMsg}`, 'error');
      }
    },
  });

  // Connection event handlers are wired in App.tsx

  // Global key bindings (when no overlay)
  useInput(
    (input, key) => {
      if (overlay) return;

      if (key.ctrl && input === 'n') {
        const defaultCwd = cwd ?? '';
        setOverlay({
          kind: 'local-input',
          title: 'New session: working directory',
          placeholder: defaultCwd,
          onSubmit: (cwdValue) => {
            if (!cwdValue) { setOverlay(null); return; }
            setOverlay({
              kind: 'local-input',
              title: 'Model (provider:model_id, or empty for default)',
              placeholder: '',
              onSubmit: (modelSpec) => {
                pendingAutoSwitch.current = true;
                connection.startSession({
                  cwd: cwdValue,
                  model: modelSpec || undefined,
                });
                setOverlay(null);
              },
            });
          },
        });
        return;
      }

      if (key.ctrl && input === 'o') {
        setToolPanelCollapsed((c) => !c);
        return;
      }

      // Ctrl+T — toggle thinking expansion for last assistant message with thinking
      if (key.ctrl && input === 't') {
        const state = store.getState();
        const allMessages = state.messages;
        for (let i = allMessages.length - 1; i >= 0; i--) {
          const msg = allMessages[i];
          if (msg.type === 'assistant' && (msg as any).thinkingContent) {
            store.toggleThinkingExpanded(msg.id);
            break;
          }
        }
        return;
      }

      // Ctrl+D — toggle compact mode
      if (key.ctrl && input === 'd') {
        store.toggleCompactMode();
        return;
      }

      // Ctrl+S — open session picker
      if (key.ctrl && input === 's') {
        setOverlay({ kind: 'session-picker' });
        return;
      }

      // Ctrl+F — open search
      if (key.ctrl && input === 'f') {
        setOverlay({ kind: 'search', query: '' });
        return;
      }
    },
    { isActive: !overlay }
  );

  // Session home view: show when ready but no active session
  const showSessionsHome = ready && !activeSessionId;
  const showToolResults = !toolPanelCollapsed;

  return (
    <Box flexDirection="column" width="100%">
      {/* Header */}
      <Header />

      {/* Welcome screen (shown until first message) */}
      {welcomeVisible && messages.length === 0 && <WelcomeScreen />}

      {/* Sessions home (no active session) */}
      {showSessionsHome && (
        <Box flexDirection="column" marginY={1}>
          <Text bold>Active Sessions</Text>
          {Array.from(sessions.values()).map((session) => {
            const shortId = session.sessionId.slice(0, 8);
            return (
              <Box key={session.sessionId}>
                <Text color={theme.primary}>  {shortId}</Text>
                <Text color={theme.muted}> · {session.model.id} · {session.cwd}</Text>
              </Box>
            );
          })}
          <Box>
            <Text color={theme.accent}>  + New session (Ctrl+N)</Text>
          </Box>
        </Box>
      )}

      {/* Widgets */}
      <WidgetPanel />

      {/* Tool panel */}
      <ToolPanel collapsed={toolPanelCollapsed} />

      {/* Tool execution bar */}
      <ToolExecutionBar />

      {/* Messages */}
      <ErrorBoundary fallbackMessage="Message rendering error">
        <MessageList showToolResults={showToolResults} />
      </ErrorBoundary>

      {/* Notifications */}
      {notifications.map((notif) => {
        const color = notif.type === 'error' ? theme.error
          : notif.type === 'warning' ? theme.warning
          : notif.type === 'success' ? theme.success
          : theme.secondary;
        const icon = notif.type === 'error' ? '\u2717'
          : notif.type === 'warning' ? '\u26A0'
          : notif.type === 'success' ? '\u2713'
          : '\u2139';
        return <Text key={notif.id} color={color}>{icon} {notif.message}</Text>;
      })}

      {/* Status bar */}
      <StatusBar />

      {/* Error bar */}
      <ErrorBar />

      {/* Loader */}
      <Loader />

      {/* Tool hint */}
      <ToolHint collapsed={toolPanelCollapsed} />

      {/* Input editor */}
      <InputEditor
        ref={editorRef}
        onSubmit={handleInput}
        autocompleteProvider={autocompleteProvider}
        isFocused={!overlay}
      />

      {/* Modeline */}
      <Modeline />

      {/* Overlays */}
      {overlay?.kind === 'select' && (
        <SelectOverlay
          title={(overlay.request.params as SelectParams).title}
          options={(overlay.request.params as SelectParams).options}
          onSelect={(value) => dismissOverlay(overlay.request.id, value)}
          onCancel={() => dismissOverlay(overlay.request.id, null, 'cancelled')}
        />
      )}
      {overlay?.kind === 'confirm' && (
        <ConfirmOverlay
          title={(overlay.request.params as ConfirmParams).title}
          message={(overlay.request.params as ConfirmParams).message}
          onConfirm={(confirmed) => dismissOverlay(overlay.request.id, confirmed)}
        />
      )}
      {overlay?.kind === 'input' && (
        <InputOverlay
          title={(overlay.request.params as InputParams).title}
          placeholder={(overlay.request.params as InputParams).placeholder}
          onSubmit={(value) => dismissOverlay(overlay.request.id, value)}
          onCancel={() => dismissOverlay(overlay.request.id, null, 'cancelled')}
        />
      )}
      {overlay?.kind === 'editor' && (
        <EditorOverlay
          title={(overlay.request.params as EditorParams).title}
          prefill={(overlay.request.params as EditorParams).prefill}
          onSubmit={(value) => dismissOverlay(overlay.request.id, value)}
          onCancel={() => dismissOverlay(overlay.request.id, null, 'cancelled')}
        />
      )}
      {overlay?.kind === 'settings' && (
        <SettingsOverlay onClose={() => setOverlay(null)} />
      )}
      {overlay?.kind === 'help' && (
        <HelpOverlay onClose={() => setOverlay(null)} />
      )}
      {overlay?.kind === 'stats' && (
        <StatsOverlay onClose={() => setOverlay(null)} />
      )}
      {overlay?.kind === 'search' && (
        <SearchOverlay
          initialQuery={overlay.query}
          onClose={() => setOverlay(null)}
        />
      )}
      {overlay?.kind === 'notifications' && (
        <NotificationHistoryOverlay onClose={() => setOverlay(null)} />
      )}
      {overlay?.kind === 'session-picker' && (
        <SessionPickerOverlay
          onClose={() => setOverlay(null)}
          onSwitchSession={(sessionId) => {
            connection.setActiveSession(sessionId);
          }}
          onNewSession={() => {
            setOverlay(null);
            const defaultCwd = cwd ?? '';
            setOverlay({
              kind: 'local-input',
              title: 'New session: working directory',
              placeholder: defaultCwd,
              onSubmit: (cwdValue) => {
                if (!cwdValue) { setOverlay(null); return; }
                setOverlay({
                  kind: 'local-input',
                  title: 'Model (provider:model_id, or empty for default)',
                  placeholder: '',
                  onSubmit: (modelSpec) => {
                    pendingAutoSwitch.current = true;
                    connection.startSession({
                      cwd: cwdValue,
                      model: modelSpec || undefined,
                    });
                    setOverlay(null);
                  },
                });
              },
            });
          }}
        />
      )}
      {overlay?.kind === 'local-select' && (
        <SelectOverlay
          title={overlay.title}
          options={overlay.options}
          onSelect={(value) => {
            overlay.onSelect(value);
            setOverlay(null);
          }}
          onCancel={() => setOverlay(null)}
        />
      )}
      {overlay?.kind === 'local-input' && (
        <InputOverlay
          title={overlay.title}
          placeholder={overlay.placeholder}
          onSubmit={(value) => {
            overlay.onSubmit(value);
          }}
          onCancel={() => setOverlay(null)}
        />
      )}
    </Box>
  );
}
