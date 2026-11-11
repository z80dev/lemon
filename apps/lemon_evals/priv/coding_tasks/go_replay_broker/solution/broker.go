package replay

import "sync"

type topic struct {
	latest  uint64
	history []Message
	subs    map[*Subscription]struct{}
}
type Broker struct {
	mu     sync.Mutex
	retain int
	closed bool
	topics map[string]*topic
}
type Subscription struct {
	C      <-chan Message
	ch     chan Message
	broker *Broker
	topic  *topic
	done   bool
	err    error
}

func New(retain int) (*Broker, error) {
	if retain < 0 {
		return nil, ErrInvalid
	}
	return &Broker{retain: retain, topics: map[string]*topic{}}, nil
}
func (b *Broker) get(name string) *topic {
	t := b.topics[name]
	if t == nil {
		t = &topic{subs: map[*Subscription]struct{}{}}
		b.topics[name] = t
	}
	return t
}
func clone(m Message) Message { return Message{m.Sequence, append([]byte(nil), m.Payload...)} }
func (b *Broker) Subscribe(name string, after uint64, buffer int) (*Subscription, error) {
	if name == "" || buffer < 1 {
		return nil, ErrInvalid
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return nil, ErrClosed
	}
	t := b.get(name)
	if after > t.latest {
		return nil, ErrCursor
	}
	if after < t.latest-uint64(len(t.history)) {
		return nil, ErrExpired
	}
	count := t.latest - after
	if count > uint64(buffer) {
		return nil, ErrBacklog
	}
	ch := make(chan Message, buffer)
	sub := &Subscription{C: ch, ch: ch, broker: b, topic: t}
	for _, m := range t.history {
		if m.Sequence > after {
			ch <- clone(m)
		}
	}
	t.subs[sub] = struct{}{}
	return sub, nil
}
func (b *Broker) Publish(name string, payload []byte) (uint64, error) {
	if name == "" {
		return 0, ErrInvalid
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return 0, ErrClosed
	}
	t := b.get(name)
	t.latest++
	m := Message{t.latest, append([]byte(nil), payload...)}
	if b.retain > 0 {
		t.history = append(t.history, m)
		if len(t.history) > b.retain {
			copy(t.history, t.history[1:])
			t.history = t.history[:b.retain]
		}
	}
	for sub := range t.subs {
		select {
		case sub.ch <- clone(m):
		default:
			sub.stop(ErrSlow)
		}
	}
	return t.latest, nil
}

// stop is called only while the broker lock is held.
func (s *Subscription) stop(err error) {
	if s.done {
		return
	}
	s.done = true
	s.err = err
	delete(s.topic.subs, s)
	close(s.ch)
}
func (s *Subscription) Cancel()    { s.broker.mu.Lock(); defer s.broker.mu.Unlock(); s.stop(nil) }
func (s *Subscription) Err() error { s.broker.mu.Lock(); defer s.broker.mu.Unlock(); return s.err }
func (b *Broker) Close() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return nil
	}
	b.closed = true
	for _, t := range b.topics {
		for sub := range t.subs {
			sub.stop(ErrClosed)
		}
	}
	return nil
}
