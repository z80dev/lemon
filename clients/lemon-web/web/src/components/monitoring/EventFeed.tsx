import { useCallback, useMemo, useRef, useState, useEffect } from 'react';
import { useMonitoringStore } from '../../store/monitoringStore';
import type { FeedEvent } from '../../../../shared/src/monitoringTypes';

export interface EventFeedProps {
  collapsed?: boolean;
}

type LevelFilter = 'all' | 'info' | 'warn' | 'error';

const EVENT_NAME_COLORS: Record<string, string> = {
  agent: '#5599ff',
  chat: '#888',
  task: '#00ff88',
  'task.started': '#00ff88',
  'task.completed': '#00ff88',
  'task.error': '#ff4444',
  'task.timeout': '#ffaa00',
  'task.aborted': '#888',
  'run.graph.changed': '#5599ff',
  heartbeat: '#666',
  cron: '#ffaa00',
  'cron.job': '#ffaa00',
  presence: '#666',
  health: '#ffaa00',
};

const LEVEL_COLORS: Record<string, string> = {
  info: '#5599ff',
  warn: '#ffaa00',
  error: '#ff4444',
  debug: '#666',
};

function formatRelative(ms: number): string {
  const diff = Date.now() - ms;
  if (diff < 1000) return 'now';
  if (diff < 60_000) return `${Math.floor(diff / 1000)}s ago`;
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m ago`;
  return `${Math.floor(diff / 3_600_000)}h ago`;
}

const MAX_VISIBLE_EVENTS = 200;

export function EventFeed({ collapsed = false }: EventFeedProps) {
  const eventFeed = useMonitoringStore((s) => s.eventFeed);
  const isPaused = useMonitoringStore((s) => s.ui.eventFeedPaused);
  const setEventFeedPaused = useMonitoringStore((s) => s.setEventFeedPaused);
  const clearEventFeed = useMonitoringStore((s) => s.clearEventFeed);

  const [filterText, setFilterText] = useState('');
  const [levelFilter, setLevelFilter] = useState<LevelFilter>('all');
  const [expandedIds, setExpandedIds] = useState<Set<string>>(new Set());
  const [userScrolled, setUserScrolled] = useState(false);

  const listRef = useRef<HTMLDivElement>(null);

  const filteredEvents = useMemo<FeedEvent[]>(() => {
    let events = eventFeed;

    // Level filter
    if (levelFilter !== 'all') {
      events = events.filter((ev) => ev.level === levelFilter);
    }

    // Text filter (regex)
    if (filterText.trim()) {
      try {
        const re = new RegExp(filterText, 'i');
        events = events.filter((ev) => re.test(ev.eventName));
      } catch {
        // Invalid regex - fall back to simple includes
        const q = filterText.toLowerCase();
        events = events.filter((ev) => ev.eventName.toLowerCase().includes(q));
      }
    }

    // Reverse for newest first, cap visible
    return events.slice(-MAX_VISIBLE_EVENTS).reverse();
  }, [eventFeed, levelFilter, filterText]);

  const handleScroll = useCallback(() => {
    const el = listRef.current;
    if (!el) return;
    // If user scrolls away from top, mark as scrolled
    setUserScrolled(el.scrollTop > 50);
  }, []);

  const scrollToTop = useCallback(() => {
    listRef.current?.scrollTo({ top: 0, behavior: 'smooth' });
    setUserScrolled(false);
  }, []);

  const toggleExpand = useCallback((id: string) => {
    setExpandedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }, []);

  // Auto-scroll to top when new events arrive (if not user-scrolled)
  useEffect(() => {
    if (!userScrolled && listRef.current) {
      listRef.current.scrollTop = 0;
    }
  }, [eventFeed.length, userScrolled]);

  const btnStyle = (active: boolean): React.CSSProperties => ({
    padding: '2px 6px',
    border: '1px solid #333',
    borderRadius: '3px',
    background: active ? '#003322' : 'transparent',
    color: active ? '#00ff88' : '#888',
    fontFamily: 'monospace',
    fontSize: '10px',
    cursor: 'pointer',
  });

  // Collapsed view - thin right column
  if (collapsed) {
    return (
      <div
        data-testid="event-feed-collapsed"
        style={{
          width: '200px',
          background: '#141414',
          borderLeft: '1px solid #333',
          fontFamily: 'monospace',
          fontSize: '10px',
          color: '#e0e0e0',
          overflowY: 'auto',
          flexShrink: 0,
        }}
      >
        <div style={{ padding: '6px 8px', borderBottom: '1px solid #333', fontWeight: 'bold' }}>
          Events
        </div>
        {filteredEvents.slice(0, 50).map((ev) => (
          <div
            key={ev.id}
            style={{
              padding: '2px 8px',
              borderBottom: '1px solid #1a1a1a',
              display: 'flex',
              alignItems: 'center',
              gap: '4px',
            }}
          >
            <span
              style={{
                width: '4px',
                height: '4px',
                borderRadius: '50%',
                background: LEVEL_COLORS[ev.level] ?? '#666',
                flexShrink: 0,
              }}
            />
            <span style={{ color: EVENT_NAME_COLORS[ev.eventName] ?? '#aaa', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              {ev.eventName}
            </span>
          </div>
        ))}
      </div>
    );
  }

  // Full view
  return (
    <div
      data-testid="event-feed"
      style={{
        fontFamily: 'monospace',
        fontSize: '11px',
        color: '#e0e0e0',
        display: 'flex',
        flexDirection: 'column',
        height: '100%',
      }}
    >
      {/* Controls */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: '8px',
          marginBottom: '8px',
          flexWrap: 'wrap',
        }}
      >
        <span style={{ fontWeight: 'bold', fontSize: '13px' }}>Events</span>
        <button
          type="button"
          data-testid="pause-btn"
          onClick={() => setEventFeedPaused(!isPaused)}
          style={btnStyle(isPaused)}
        >
          {isPaused ? 'Resume' : 'Pause'}
        </button>
        <button
          type="button"
          data-testid="clear-btn"
          onClick={clearEventFeed}
          style={btnStyle(false)}
        >
          Clear
        </button>
        <input
          data-testid="event-filter-input"
          placeholder="Filter events..."
          value={filterText}
          onChange={(e) => setFilterText(e.target.value)}
          style={{
            background: '#1a1a1a',
            border: '1px solid #333',
            borderRadius: '3px',
            color: '#e0e0e0',
            fontFamily: 'monospace',
            fontSize: '11px',
            padding: '3px 6px',
            outline: 'none',
            width: '160px',
          }}
        />
        {/* Level filters */}
        {(['all', 'info', 'warn', 'error'] as LevelFilter[]).map((level) => (
          <button
            key={level}
            type="button"
            data-testid={`level-filter-${level}`}
            onClick={() => setLevelFilter(level)}
            style={btnStyle(levelFilter === level)}
          >
            {level.charAt(0).toUpperCase() + level.slice(1)}
          </button>
        ))}
        <span style={{ color: '#666' }}>
          {filteredEvents.length} event{filteredEvents.length !== 1 ? 's' : ''}
        </span>
      </div>

      {/* Event list */}
      <div
        ref={listRef}
        data-testid="event-list"
        onScroll={handleScroll}
        style={{
          flex: 1,
          overflowY: 'auto',
          position: 'relative',
        }}
      >
        {userScrolled && (
          <button
            type="button"
            data-testid="scroll-to-new"
            onClick={scrollToTop}
            style={{
              position: 'sticky',
              top: 0,
              zIndex: 1,
              width: '100%',
              padding: '4px',
              background: '#003322',
              border: 'none',
              color: '#00ff88',
              fontFamily: 'monospace',
              fontSize: '10px',
              cursor: 'pointer',
              textAlign: 'center',
            }}
          >
            {'\u2193'} New events
          </button>
        )}

        {filteredEvents.length === 0 ? (
          <div
            data-testid="event-feed-empty"
            style={{ color: '#666', padding: '16px', textAlign: 'center' }}
          >
            No events
          </div>
        ) : (
          filteredEvents.map((ev) => {
            const isExpanded = expandedIds.has(ev.id);
            return (
              <div
                key={ev.id}
                data-testid={`event-item-${ev.id}`}
                style={{
                  borderBottom: '1px solid #1a1a1a',
                  padding: '4px 0',
                }}
              >
                <div
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: '8px',
                    cursor: 'pointer',
                  }}
                  onClick={() => toggleExpand(ev.id)}
                >
                  <span style={{ color: '#666', width: '52px', flexShrink: 0, fontSize: '10px' }}>
                    {formatRelative(ev.receivedAtMs)}
                  </span>
                  <span
                    style={{
                      color: EVENT_NAME_COLORS[ev.eventName] ?? '#aaa',
                      width: '100px',
                      flexShrink: 0,
                    }}
                  >
                    {ev.eventName}
                  </span>
                  <span
                    style={{
                      padding: '0 4px',
                      borderRadius: '2px',
                      background: (LEVEL_COLORS[ev.level] ?? '#666') + '22',
                      color: LEVEL_COLORS[ev.level] ?? '#666',
                      fontSize: '9px',
                      textTransform: 'uppercase',
                    }}
                  >
                    {ev.level}
                  </span>
                  {ev.runId && (
                    <span style={{ color: '#666', fontSize: '10px' }}>
                      {ev.runId.slice(0, 8)}
                    </span>
                  )}
                  <span style={{ color: '#555', marginLeft: 'auto', fontSize: '10px' }}>
                    {isExpanded ? '\u25BC' : '\u25B6'}
                  </span>
                </div>
                {isExpanded && (
                  <pre
                    data-testid={`event-payload-${ev.id}`}
                    style={{
                      margin: '4px 0 4px 60px',
                      padding: '6px 8px',
                      background: '#111',
                      borderRadius: '3px',
                      color: '#aaa',
                      fontSize: '10px',
                      overflow: 'auto',
                      maxHeight: '200px',
                      whiteSpace: 'pre-wrap',
                      wordBreak: 'break-all',
                    }}
                  >
                    {JSON.stringify(ev.payload, null, 2)}
                  </pre>
                )}
              </div>
            );
          })
        )}
      </div>
    </div>
  );
}
