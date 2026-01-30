import { useMemo, useRef, useEffect } from 'react';
import { useLemonStore } from '../store/useLemonStore';
import { MessageCard } from './MessageCard';

export function ChatView() {
  const activeSessionId = useLemonStore((state) => state.sessions.activeSessionId);
  const messages = useLemonStore(
    (state) => (activeSessionId ? state.messagesBySession[activeSessionId] : []) ?? []
  );

  const feedRef = useRef<HTMLDivElement | null>(null);

  const messageList = useMemo(() => messages ?? [], [messages]);

  useEffect(() => {
    if (!feedRef.current) return;
    feedRef.current.scrollTop = feedRef.current.scrollHeight;
  }, [messageList.length]);

  return (
    <section className="chat-view">
      <div className="chat-header">
        <h2>Conversation</h2>
        <span className="chat-count">{messageList.length} messages</span>
      </div>
      <div className="message-feed" ref={feedRef}>
        {messageList.length === 0 ? (
          <div className="empty-state">
            <p>No messages yet. Start a session and send a prompt.</p>
          </div>
        ) : (
          messageList.map((message) => {
            const key =
              message.role === 'tool_result'
                ? `${message.tool_call_id}-${message.timestamp}`
                : `${message.role}-${message.timestamp}`;
            return <MessageCard key={key} message={message} />;
          })
        )}
      </div>
    </section>
  );
}
