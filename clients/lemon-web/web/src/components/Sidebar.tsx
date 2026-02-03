import { useEffect, useMemo, useState } from 'react';
import { useLemonStore } from '../store/useLemonStore';

export function Sidebar() {
  const runningSessions = useLemonStore((state) => state.sessions.running);
  const savedSessions = useLemonStore((state) => state.sessions.saved);
  const activeSessionId = useLemonStore((state) => state.sessions.activeSessionId);
  const models = useLemonStore((state) => state.models);
  const statsBySession = useLemonStore((state) => state.statsBySession);
  const editorText = useLemonStore((state) => state.ui.editorText);
  const debugLog = useLemonStore((state) => state.debugLog);
  const send = useLemonStore((state) => state.send);
  const setAutoActivateNextSession = useLemonStore(
    (state) => state.setAutoActivateNextSession
  );
  const config = useLemonStore((state) => state.config);
  const setConfig = useLemonStore((state) => state.setConfig);

  const [showDebug, setShowDebug] = useState(false);
  const [showNewSession, setShowNewSession] = useState(false);
  const [newSession, setNewSession] = useState({
    cwd: '',
    providerId: '',
    modelId: '',
    modelSpec: '',
    systemPrompt: '',
    sessionFile: '',
    parentSession: '',
    autoActivate: true,
  });

  const runningList = useMemo(() => Object.values(runningSessions), [runningSessions]);
  const activeRunning = useMemo(
    () => (activeSessionId ? runningSessions[activeSessionId] : undefined),
    [activeSessionId, runningSessions]
  );
  const activeStats = useMemo(
    () => (activeSessionId ? statsBySession[activeSessionId] : undefined),
    [activeSessionId, statsBySession]
  );

  const cwdSuggestions = useMemo(() => {
    const values = new Set<string>();
    if (activeRunning?.cwd) values.add(activeRunning.cwd);
    for (const session of runningList) {
      if (session.cwd) values.add(session.cwd);
    }
    for (const session of savedSessions) {
      if (session.cwd) values.add(session.cwd);
    }
    return Array.from(values);
  }, [activeRunning, runningList, savedSessions]);

  const sessionFileSuggestions = useMemo(
    () => savedSessions.map((session) => session.path),
    [savedSessions]
  );

  const providerOptions = useMemo(() => models ?? [], [models]);
  const modelOptions = useMemo(() => {
    if (providerOptions.length === 0) return [];
    const selectedProvider =
      providerOptions.find((provider) => provider.id === newSession.providerId) ??
      providerOptions[0];
    return selectedProvider?.models ?? [];
  }, [providerOptions, newSession.providerId]);

  useEffect(() => {
    if (!showNewSession) return;
    setNewSession((prev) => {
      const next = { ...prev };
      if (!next.cwd) {
        next.cwd =
          activeRunning?.cwd ||
          runningList[0]?.cwd ||
          savedSessions[0]?.cwd ||
          '';
      }
      if (providerOptions.length > 0 && !next.providerId) {
        const preferredProvider = activeStats?.model.provider;
        const provider =
          providerOptions.find((item) => item.id === preferredProvider) ?? providerOptions[0];
        next.providerId = provider?.id ?? '';
      }
      if (providerOptions.length > 0 && !next.modelId) {
        const provider =
          providerOptions.find((item) => item.id === next.providerId) ?? providerOptions[0];
        const preferredModel = activeStats?.model.id;
        const model =
          provider?.models?.find((item) => item.id === preferredModel) ??
          provider?.models?.[0];
        next.modelId = model?.id ?? '';
      }
      return next;
    });
  }, [showNewSession, activeRunning, activeStats, runningList, savedSessions, providerOptions]);

  return (
    <aside className="sidebar">
      <div className="sidebar-section">
        <div className="section-header">
          <h2>Sessions</h2>
          <div className="section-actions">
            <button
              className="ghost-button"
              type="button"
              onClick={() => send({ type: 'list_running_sessions' })}
            >
              Refresh
            </button>
            <button
              className="ghost-button"
              type="button"
              onClick={() => setShowNewSession((value) => !value)}
            >
              {showNewSession ? 'Close' : 'New'}
            </button>
          </div>
        </div>
        {showNewSession ? (
          <form
            className="panel"
            onSubmit={(event) => {
              event.preventDefault();
              const modelSpec =
                providerOptions.length > 0
                  ? newSession.providerId && newSession.modelId
                    ? `${newSession.providerId}:${newSession.modelId}`
                    : ''
                  : newSession.modelSpec;
              setAutoActivateNextSession(newSession.autoActivate);
              send({
                type: 'start_session',
                cwd: newSession.cwd || undefined,
                model: modelSpec || undefined,
                system_prompt: newSession.systemPrompt || undefined,
                session_file: newSession.sessionFile || undefined,
                parent_session: newSession.parentSession || undefined,
              });
            }}
          >
            <label>
              CWD
              <input
                list="cwd-suggestions"
                value={newSession.cwd}
                onChange={(event) =>
                  setNewSession((prev) => ({ ...prev, cwd: event.target.value }))
                }
                placeholder="/path/to/project"
              />
              {cwdSuggestions.length > 0 ? (
                <datalist id="cwd-suggestions">
                  {cwdSuggestions.map((cwd) => (
                    <option key={cwd} value={cwd} />
                  ))}
                </datalist>
              ) : null}
            </label>
            {providerOptions.length > 0 ? (
              <>
                <label>
                  Provider
                  <select
                    value={newSession.providerId}
                    onChange={(event) => {
                      const providerId = event.target.value;
                      const provider =
                        providerOptions.find((item) => item.id === providerId) ??
                        providerOptions[0];
                      const firstModel = provider?.models?.[0]?.id ?? '';
                      setNewSession((prev) => ({
                        ...prev,
                        providerId,
                        modelId: firstModel,
                      }));
                    }}
                  >
                    {providerOptions.map((provider) => (
                      <option key={provider.id} value={provider.id}>
                        {provider.id}
                      </option>
                    ))}
                  </select>
                </label>
                <label>
                  Model
                  <select
                    value={newSession.modelId}
                    onChange={(event) =>
                      setNewSession((prev) => ({ ...prev, modelId: event.target.value }))
                    }
                  >
                    {modelOptions.map((model) => (
                      <option key={model.id} value={model.id}>
                        {model.name ? `${model.id} — ${model.name}` : model.id}
                      </option>
                    ))}
                  </select>
                </label>
              </>
            ) : (
              <label>
                Model
                <input
                  value={newSession.modelSpec}
                  onChange={(event) =>
                    setNewSession((prev) => ({ ...prev, modelSpec: event.target.value }))
                  }
                  placeholder="provider:model_id"
                />
              </label>
            )}
            <label>
              System Prompt
              <textarea
                rows={3}
                value={newSession.systemPrompt}
                onChange={(event) =>
                  setNewSession((prev) => ({ ...prev, systemPrompt: event.target.value }))
                }
                placeholder="Leave empty for default (same as TUI)."
              />
            </label>
            <label>
              Session File
              <input
                list="session-file-suggestions"
                value={newSession.sessionFile}
                onChange={(event) =>
                  setNewSession((prev) => ({ ...prev, sessionFile: event.target.value }))
                }
                placeholder="/path/to/session.jsonl"
              />
              {sessionFileSuggestions.length > 0 ? (
                <datalist id="session-file-suggestions">
                  {sessionFileSuggestions.map((path) => (
                    <option key={path} value={path} />
                  ))}
                </datalist>
              ) : null}
            </label>
            <label>
              Parent Session
              <select
                value={newSession.parentSession}
                onChange={(event) =>
                  setNewSession((prev) => ({ ...prev, parentSession: event.target.value }))
                }
              >
                <option value="">None</option>
                {runningList.map((session) => (
                  <option key={session.session_id} value={session.session_id}>
                    {session.session_id}
                  </option>
                ))}
              </select>
            </label>
            <label className="checkbox-row">
              <input
                type="checkbox"
                checked={newSession.autoActivate}
                onChange={(event) =>
                  setNewSession((prev) => ({ ...prev, autoActivate: event.target.checked }))
                }
              />
              Auto-activate new session
            </label>
            <button className="pill-button" type="submit">
              Start Session
            </button>
          </form>
        ) : null}
        <div className="list">
          {runningList.length === 0 ? (
            <p className="muted">No running sessions.</p>
          ) : (
            runningList.map((session) => (
              <div
                key={session.session_id}
                className={`list-item ${
                  activeSessionId === session.session_id ? 'list-item--active' : ''
                }`}
              >
                <div>
                  <div className="list-item__title">{session.session_id}</div>
                  <div className="list-item__meta">{session.cwd}</div>
                </div>
                <div className="list-item__actions">
                  <button
                    className="ghost-button"
                    type="button"
                    onClick={() =>
                      send({ type: 'set_active_session', session_id: session.session_id })
                    }
                  >
                    Activate
                  </button>
                  <button
                    className="ghost-button ghost-button--danger"
                    type="button"
                    onClick={() => send({ type: 'close_session', session_id: session.session_id })}
                  >
                    Close
                  </button>
                </div>
              </div>
            ))
          )}
        </div>
      </div>

      <div className="sidebar-section">
        <div className="section-header">
          <h2>Saved Sessions</h2>
          <button
            className="ghost-button"
            type="button"
            onClick={() => send({ type: 'list_sessions' })}
          >
            Refresh
          </button>
        </div>
        <div className="list">
          {savedSessions.length === 0 ? (
            <p className="muted">No saved sessions.</p>
          ) : (
            savedSessions.map((session) => (
              <div key={session.id} className="list-item">
                <div>
                  <div className="list-item__title">{session.id}</div>
                  <div className="list-item__meta">{session.cwd}</div>
                </div>
                <button
                  className="ghost-button"
                  type="button"
                  onClick={() =>
                    send({
                      type: 'start_session',
                      session_file: session.path,
                    })
                  }
                >
                  Open
                </button>
              </div>
            ))
          )}
        </div>
      </div>

      <div className="sidebar-section">
        <div className="section-header">
          <h2>Models</h2>
          <button
            className="ghost-button"
            type="button"
            onClick={() => send({ type: 'list_models' })}
          >
            Refresh
          </button>
        </div>
        <div className="list list--compact">
          {models.length === 0 ? (
            <p className="muted">No models loaded.</p>
          ) : (
            models.map((provider) => (
              <div key={provider.id} className="list-item list-item--stacked">
                <div className="list-item__title">{provider.id}</div>
                <div className="tag-list">
                  {provider.models.map((model) => (
                    <span key={model.id} className="tag">
                      {model.id}
                    </span>
                  ))}
                </div>
              </div>
            ))
          )}
        </div>
      </div>

      <div className="sidebar-section">
        <div className="section-header">
          <h2>Editor</h2>
        </div>
        <div className="panel panel--editor">
          <pre>{editorText || 'No editor text set.'}</pre>
        </div>
      </div>

      <div className="sidebar-section">
        <div className="section-header">
          <h2>Settings</h2>
          <button
            className="ghost-button"
            type="button"
            onClick={() => send({ type: 'get_config' })}
          >
            Refresh
          </button>
        </div>
        <div className="panel">
          <label className="checkbox-row">
            <input
              type="checkbox"
              checked={config.claude_skip_permissions}
              onChange={(event) =>
                setConfig('claude_skip_permissions', event.target.checked)
              }
            />
            Claude: Skip Permissions
          </label>
          <label className="checkbox-row">
            <input
              type="checkbox"
              checked={config.codex_auto_approve}
              onChange={(event) =>
                setConfig('codex_auto_approve', event.target.checked)
              }
            />
            Codex: Auto Approve
          </label>
        </div>
      </div>

      <div className="sidebar-section">
        <div className="section-header">
          <h2>Debug</h2>
          <button
            className="ghost-button"
            type="button"
            onClick={() => setShowDebug((value) => !value)}
          >
            {showDebug ? 'Hide' : 'Show'}
          </button>
        </div>
        <div className="section-actions">
          <button className="ghost-button ghost-button--danger" onClick={() => send({ type: 'quit' })}>
            Quit RPC
          </button>
        </div>
        {showDebug ? (
          <div className="panel panel--debug">
            {debugLog.length === 0 ? (
              <p className="muted">No debug events yet.</p>
            ) : (
              debugLog.map((entry, index) => (
                <pre key={`${entry.type}-${index}`}>{JSON.stringify(entry, null, 2)}</pre>
              ))
            )}
          </div>
        ) : (
          <p className="muted">Toggle to inspect raw RPC traffic.</p>
        )}
      </div>
    </aside>
  );
}
