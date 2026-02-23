import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { EventFeed } from './EventFeed';
import { useMonitoringStore, INITIAL_INSTANCE, INITIAL_UI } from '../../store/monitoringStore';
import type { FeedEvent } from '../../../../shared/src/monitoringTypes';

function makeFeedEvent(overrides: Partial<FeedEvent> = {}): FeedEvent {
  return {
    id: `feed-${Math.random().toString(36).slice(2, 8)}`,
    eventName: 'agent',
    payload: { type: 'started' },
    seq: 1,
    receivedAtMs: Date.now(),
    runId: 'run-1',
    level: 'info',
    ...overrides,
  };
}

function resetStore() {
  useMonitoringStore.setState({
    instance: { ...INITIAL_INSTANCE },
    eventFeed: [],
    ui: { ...INITIAL_UI, eventFeedPaused: false, filters: { ...INITIAL_UI.filters, eventTypes: [] } },
  });
}

describe('EventFeed', () => {
  beforeEach(() => resetStore());
  afterEach(() => resetStore());

  it('renders event list from store', () => {
    const ev1 = makeFeedEvent({ id: 'ev-render-1', eventName: 'agent' });
    const ev2 = makeFeedEvent({ id: 'ev-render-2', eventName: 'heartbeat' });
    useMonitoringStore.setState({ eventFeed: [ev1, ev2] });
    render(<EventFeed />);
    expect(screen.getByTestId('event-feed')).toBeInTheDocument();
    expect(screen.getByTestId('event-item-ev-render-1')).toBeInTheDocument();
    expect(screen.getByTestId('event-item-ev-render-2')).toBeInTheDocument();
  });

  it('pause button calls setEventFeedPaused', () => {
    render(<EventFeed />);
    const pauseBtn = screen.getByTestId('pause-btn');
    expect(pauseBtn.textContent).toBe('Pause');
    fireEvent.click(pauseBtn);
    expect(useMonitoringStore.getState().ui.eventFeedPaused).toBe(true);
  });

  it('clear button calls clearEventFeed', () => {
    const ev = makeFeedEvent({ id: 'ev-clear' });
    useMonitoringStore.setState({ eventFeed: [ev] });
    render(<EventFeed />);
    const clearBtn = screen.getByTestId('clear-btn');
    fireEvent.click(clearBtn);
    expect(useMonitoringStore.getState().eventFeed).toHaveLength(0);
  });

  it('filter input filters events by name', () => {
    const ev1 = makeFeedEvent({ id: 'ev-f1', eventName: 'agent' });
    const ev2 = makeFeedEvent({ id: 'ev-f2', eventName: 'heartbeat' });
    const ev3 = makeFeedEvent({ id: 'ev-f3', eventName: 'agent' });
    useMonitoringStore.setState({ eventFeed: [ev1, ev2, ev3] });
    render(<EventFeed />);

    const filterInput = screen.getByTestId('event-filter-input');
    fireEvent.change(filterInput, { target: { value: 'heartbeat' } });

    expect(screen.getByText('1 event')).toBeInTheDocument();
  });

  it('level filter works', () => {
    const ev1 = makeFeedEvent({ id: 'ev-l1', level: 'info' });
    const ev2 = makeFeedEvent({ id: 'ev-l2', level: 'warn' });
    const ev3 = makeFeedEvent({ id: 'ev-l3', level: 'error' });
    useMonitoringStore.setState({ eventFeed: [ev1, ev2, ev3] });
    render(<EventFeed />);

    // Click "Error" filter
    fireEvent.click(screen.getByTestId('level-filter-error'));
    expect(screen.getByText('1 event')).toBeInTheDocument();
  });

  it('JSON expand works on event click', () => {
    const ev = makeFeedEvent({ id: 'ev-expand', payload: { foo: 'bar' } });
    useMonitoringStore.setState({ eventFeed: [ev] });
    render(<EventFeed />);

    // Click event to expand
    const eventItem = screen.getByTestId('event-item-ev-expand');
    fireEvent.click(eventItem.querySelector('div')!);

    const payload = screen.getByTestId('event-payload-ev-expand');
    expect(payload.textContent).toContain('"foo"');
    expect(payload.textContent).toContain('"bar"');
  });

  it('shows collapsed view correctly', () => {
    const ev = makeFeedEvent({ id: 'ev-collapsed', eventName: 'agent' });
    useMonitoringStore.setState({ eventFeed: [ev] });
    render(<EventFeed collapsed />);
    expect(screen.getByTestId('event-feed-collapsed')).toBeInTheDocument();
    // Should show event name in collapsed view
    expect(screen.getByText('agent')).toBeInTheDocument();
  });

  it('handles empty feed', () => {
    render(<EventFeed />);
    expect(screen.getByTestId('event-feed-empty')).toBeInTheDocument();
    expect(screen.getByText('No events')).toBeInTheDocument();
  });

  it('shows event count', () => {
    const events = [
      makeFeedEvent({ id: 'ev-c1' }),
      makeFeedEvent({ id: 'ev-c2' }),
      makeFeedEvent({ id: 'ev-c3' }),
    ];
    useMonitoringStore.setState({ eventFeed: events });
    render(<EventFeed />);
    expect(screen.getByText('3 events')).toBeInTheDocument();
  });

  it('resume button shows when paused', () => {
    useMonitoringStore.setState({
      ui: { ...INITIAL_UI, eventFeedPaused: true, filters: { ...INITIAL_UI.filters, eventTypes: [] } },
    });
    render(<EventFeed />);
    const pauseBtn = screen.getByTestId('pause-btn');
    expect(pauseBtn.textContent).toBe('Resume');
  });

  it('renders multiple level filter buttons', () => {
    render(<EventFeed />);
    expect(screen.getByTestId('level-filter-all')).toBeInTheDocument();
    expect(screen.getByTestId('level-filter-info')).toBeInTheDocument();
    expect(screen.getByTestId('level-filter-warn')).toBeInTheDocument();
    expect(screen.getByTestId('level-filter-error')).toBeInTheDocument();
  });
});
