package replay

type Broker struct {
	retain int
	closed bool
	seq    map[string]uint64
	subs   map[string][]*Subscription
}
type Subscription struct {
	C      <-chan Message
	ch     chan Message
	err    error
	closed bool
}

func New(retain int) (*Broker, error) {
	if retain < 0 {
		return nil, ErrInvalid
	}
	return &Broker{retain: retain, seq: map[string]uint64{}, subs: map[string][]*Subscription{}}, nil
}
func (b *Broker) Subscribe(topic string, after uint64, buffer int) (*Subscription, error) {
	if topic == "" || buffer < 1 {
		return nil, ErrInvalid
	}
	if b.closed {
		return nil, ErrClosed
	}
	ch := make(chan Message, buffer)
	s := &Subscription{C: ch, ch: ch}
	b.subs[topic] = append(b.subs[topic], s)
	return s, nil
}
func (b *Broker) Publish(topic string, payload []byte) (uint64, error) {
	if b.closed {
		return 0, ErrClosed
	}
	b.seq[topic]++
	for _, s := range b.subs[topic] {
		if !s.closed {
			s.ch <- Message{b.seq[topic], payload}
		}
	}
	return b.seq[topic], nil
}
func (s *Subscription) Cancel() {
	if !s.closed {
		s.closed = true
		close(s.ch)
	}
}
func (s *Subscription) Err() error { return s.err }
func (b *Broker) Close() error {
	b.closed = true
	for _, subs := range b.subs {
		for _, s := range subs {
			s.Cancel()
		}
	}
	return nil
}
