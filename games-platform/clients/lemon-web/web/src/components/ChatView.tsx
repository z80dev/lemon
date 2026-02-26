import { useMemo, useRef, useEffect, useCallback } from 'react';
import { useLemonStore, getMessageKey } from '../store/useLemonStore';
import { MessageCard } from './MessageCard';

/** Distance from bottom (in pixels) at which we consider user "near bottom" for auto-scroll */
const AUTO_SCROLL_THRESHOLD = 100;

export function ChatView() {
  const activeSessionId = useLemonStore((state) => state.sessions.activeSessionId);
  const messages = useLemonStore(
    (state) => (activeSessionId ? state.messagesBySession[activeSessionId] : []) ?? []
  );

  const feedRef = useRef<HTMLDivElement | null>(null);
  /** Tracks whether user is near the bottom of the message feed */
  const isNearBottomRef = useRef(true);

  const messageList = useMemo(() => messages ?? [], [messages]);

  /**
   * Check if user is within AUTO_SCROLL_THRESHOLD pixels of the bottom.
   * We call this on scroll events to track user position.
   */
  const handleScroll = useCallback(() => {
    const feed = feedRef.current;
    if (!feed) return;

    const distanceFromBottom = feed.scrollHeight - feed.scrollTop - feed.clientHeight;
    isNearBottomRef.current = distanceFromBottom <= AUTO_SCROLL_THRESHOLD;
  }, []);

  /**
   * Auto-scroll to bottom when new messages arrive, but only if user was near the bottom.
   * This prevents disrupting users who are reading history further up.
   */
  useEffect(() => {
    const feed = feedRef.current;
    if (!feed) return;

    // Only auto-scroll if user is near the bottom
    if (isNearBottomRef.current) {
      feed.scrollTop = feed.scrollHeight;
    }
  }, [messageList.length]);

  /**
   * On initial mount or session change, scroll to bottom.
   */
  useEffect(() => {
    const feed = feedRef.current;
    if (!feed) return;

    // Reset to bottom on session change
    feed.scrollTop = feed.scrollHeight;
    isNearBottomRef.current = true;
  }, [activeSessionId]);

  return (
    <section className="chat-view">
      <div className="chat-header">
        <h2>Conversation</h2>
        <span className="chat-count">{messageList.length} messages</span>
      </div>
      <div className="message-feed" ref={feedRef} onScroll={handleScroll}>
        {messageList.length === 0 ? (
          <div className="empty-state">
            <p>No messages yet. Start a session and send a prompt.</p>
          </div>
        ) : (
          messageList.map((message) => (
            <MessageCard key={getMessageKey(message)} message={message} />
          ))
        )}
      </div>
    </section>
  );
}
