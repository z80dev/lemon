import { useEffect, useRef, useState } from 'react';
import { useLemonStore } from '../store/useLemonStore';

export function Composer() {
  const send = useLemonStore((state) => state.send);
  const activeSessionId = useLemonStore((state) => state.sessions.activeSessionId);
  const connectionState = useLemonStore((state) => state.connection.state);
  const sendCommand = useLemonStore((state) => state.sendCommand);
  const enqueueNotification = useLemonStore((state) => state.enqueueNotification);
  const [text, setText] = useState('');
  const [history, setHistory] = useState<string[]>([]);
  const [historyIndex, setHistoryIndex] = useState<number | null>(null);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);

  useEffect(() => {
    if (historyIndex === null) return;
    const entry = history[historyIndex] ?? '';
    setText(entry);
  }, [historyIndex, history]);

  const sendPrompt = () => {
    if (!text.trim() || !activeSessionId) return;
    if (!sendCommand) {
      enqueueNotification({
        id: `send-missing-${Date.now()}`,
        message: 'WebSocket not ready yet. Please wait a moment and try again.',
        level: 'error',
        createdAt: Date.now(),
      });
      return;
    }
    if (connectionState !== 'connected') {
      enqueueNotification({
        id: `send-disconnected-${Date.now()}`,
        message: 'Cannot send while disconnected. Check the connection and try again.',
        level: 'error',
        createdAt: Date.now(),
      });
      return;
    }
    send({ type: 'prompt', text: text.trim(), session_id: activeSessionId ?? undefined });
    setHistory((prev) => [text.trim(), ...prev].slice(0, 50));
    setHistoryIndex(null);
    setText('');
    textareaRef.current?.focus();
  };

  return (
    <div className="composer">
      <div className="composer__actions">
        <button
          className="pill-button"
          type="button"
          onClick={() => send({ type: 'abort', session_id: activeSessionId ?? undefined })}
          disabled={!activeSessionId}
        >
          Abort
        </button>
        <button
          className="pill-button"
          type="button"
          onClick={() => send({ type: 'reset', session_id: activeSessionId ?? undefined })}
          disabled={!activeSessionId}
        >
          Reset
        </button>
        <button
          className="pill-button"
          type="button"
          onClick={() => send({ type: 'save', session_id: activeSessionId ?? undefined })}
          disabled={!activeSessionId}
        >
          Save
        </button>
      </div>
      <div className="composer__input">
        <textarea
          ref={textareaRef}
          value={text}
          onChange={(event) => setText(event.target.value)}
          placeholder={
            activeSessionId
              ? 'Send a prompt… (Enter to send, Shift+Enter for newline)'
              : 'Start or activate a session to send prompts.'
          }
          onKeyDown={(event) => {
            if (event.key === 'Enter' && !event.shiftKey) {
              event.preventDefault();
              sendPrompt();
            }
            if (event.key === 'ArrowUp' && event.altKey) {
              event.preventDefault();
              setHistoryIndex((prev) => {
                const nextIndex = prev === null ? 0 : Math.min(prev + 1, history.length - 1);
                return history.length === 0 ? null : nextIndex;
              });
            }
            if (event.key === 'ArrowDown' && event.altKey) {
              event.preventDefault();
              setHistoryIndex((prev) => {
                if (prev === null) return null;
                const nextIndex = prev - 1;
                return nextIndex >= 0 ? nextIndex : null;
              });
            }
          }}
        />
        <div className="composer__footer">
          <span className="muted">Alt+↑/↓ for history</span>
          <button
            className="pill-button pill-button--primary"
            type="button"
            onClick={sendPrompt}
            disabled={!activeSessionId || connectionState !== 'connected'}
          >
            Send
          </button>
        </div>
      </div>
    </div>
  );
}
