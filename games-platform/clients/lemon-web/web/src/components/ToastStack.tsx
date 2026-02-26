import { useEffect, useRef } from 'react';
import { useLemonStore } from '../store/useLemonStore';

export function ToastStack() {
  const notifications = useLemonStore((state) => state.notifications);
  const dismiss = useLemonStore((state) => state.dismissNotification);
  const scheduled = useRef<Set<string>>(new Set());

  useEffect(() => {
    for (const note of notifications) {
      if (scheduled.current.has(note.id)) continue;
      scheduled.current.add(note.id);
      window.setTimeout(() => {
        dismiss(note.id);
        scheduled.current.delete(note.id);
      }, 6000);
    }
  }, [notifications, dismiss]);

  return (
    <div className="toast-stack">
      {notifications.map((note) => (
        <div key={note.id} className={`toast toast--${note.level}`}>
          <div>{note.message}</div>
          <button className="ghost-button" onClick={() => dismiss(note.id)}>
            Dismiss
          </button>
        </div>
      ))}
    </div>
  );
}
