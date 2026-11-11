package replay

import (
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"
)

func recv(t *testing.T, s *Subscription) Message {
	t.Helper()
	select {
	case m, ok := <-s.C:
		if !ok {
			t.Fatalf("closed early: %v", s.Err())
		}
		return m
	case <-time.After(3 * time.Second):
		t.Fatal("message missing")
		return Message{}
	}
}
func ended(t *testing.T, s *Subscription, want error) {
	t.Helper()
	select {
	case _, ok := <-s.C:
		if ok {
			t.Fatal("unexpected queued message")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("channel did not close")
	}
	if !errors.Is(s.Err(), want) {
		t.Fatalf("termination %v want %v", s.Err(), want)
	}
}
func TestReplayAndOwnership(t *testing.T) {
	b, _ := New(3)
	defer b.Close()
	a, _ := b.Subscribe("a", 0, 8)
	c, _ := b.Subscribe("a", 0, 8)
	p := []byte("one")
	b.Publish("a", p)
	p[0] = 'X'
	ma, mc := recv(t, a), recv(t, c)
	if string(ma.Payload) != "one" || string(mc.Payload) != "one" {
		t.Fatal("publisher aliases")
	}
	ma.Payload[0] = 'Z'
	if string(mc.Payload) != "one" {
		t.Fatal("subscriber aliases")
	}
	for i := 2; i <= 5; i++ {
		seq, e := b.Publish("a", []byte(fmt.Sprint(i)))
		if e != nil || seq != uint64(i) {
			t.Fatal(seq, e)
		}
	}
	if s, e := b.Subscribe("a", 1, 9); s != nil || !errors.Is(e, ErrExpired) {
		t.Fatal("expired cursor")
	}
	if s, e := b.Subscribe("a", 6, 9); s != nil || !errors.Is(e, ErrCursor) {
		t.Fatal("future cursor")
	}
	if s, e := b.Subscribe("a", 2, 2); s != nil || !errors.Is(e, ErrBacklog) {
		t.Fatal("backlog")
	}
	replay, e := b.Subscribe("a", 2, 4)
	if e != nil {
		t.Fatal(e)
	}
	for n := uint64(3); n <= 5; n++ {
		if m := recv(t, replay); m.Sequence != n {
			t.Fatal("replay order")
		}
	}
	b.Publish("a", []byte("six"))
	if m := recv(t, replay); m.Sequence != 6 {
		t.Fatal("live after replay")
	}
	b.Publish("b", nil)
	other, e := b.Subscribe("b", 0, 2)
	if e != nil || recv(t, other).Sequence != 1 {
		t.Fatal("topic isolation")
	}
	zero, _ := New(0)
	zero.Publish("z", nil)
	if s, e := zero.Subscribe("z", 0, 1); s != nil || !errors.Is(e, ErrExpired) {
		t.Fatal("zero retention cursor")
	}
	s, e := zero.Subscribe("z", 1, 1)
	if e != nil {
		t.Fatal(e)
	}
	zero.Publish("z", []byte("new"))
	if recv(t, s).Sequence != 2 {
		t.Fatal("zero retention live")
	}
	zero.Close()
}
func TestSlowCancelAndClose(t *testing.T) {
	b, _ := New(3)
	slow, _ := b.Subscribe("t", 0, 1)
	fast, _ := b.Subscribe("t", 0, 8)
	done := make(chan struct{})
	go func() { defer close(done); b.Publish("t", []byte("a")); b.Publish("t", []byte("b")) }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("publish blocked")
	}
	if !errors.Is(slow.Err(), ErrSlow) {
		t.Fatal("missing slow reason")
	}
	if recv(t, slow).Sequence != 1 {
		t.Fatal("queued value lost")
	}
	ended(t, slow, ErrSlow)
	slow.Cancel()
	if !errors.Is(slow.Err(), ErrSlow) {
		t.Fatal("reason overwritten")
	}
	if recv(t, fast).Sequence != 1 || recv(t, fast).Sequence != 2 {
		t.Fatal("healthy subscriber")
	}
	fast.Cancel()
	fast.Cancel()
	ended(t, fast, nil)
	b.Publish("t", nil)
	active, _ := b.Subscribe("t", 3, 2)
	b.Publish("t", []byte("last"))
	if e := b.Close(); e != nil {
		t.Fatal(e)
	}
	b.Close()
	if recv(t, active).Sequence != 4 {
		t.Fatal("close dropped queue")
	}
	ended(t, active, ErrClosed)
	active.Cancel()
	if !errors.Is(active.Err(), ErrClosed) {
		t.Fatal("close reason lost")
	}
	if _, e := b.Publish("t", nil); !errors.Is(e, ErrClosed) {
		t.Fatal("publish closed")
	}
	if s, e := b.Subscribe("t", 4, 1); s != nil || !errors.Is(e, ErrClosed) {
		t.Fatal("subscribe closed")
	}
	if _, e := b.Publish("", nil); !errors.Is(e, ErrInvalid) {
		t.Fatal("validation precedence")
	}
	if _, e := b.Subscribe("", 0, 0); !errors.Is(e, ErrInvalid) {
		t.Fatal("bad subscribe")
	}
	if got, e := New(-1); got != nil || !errors.Is(e, ErrInvalid) {
		t.Fatal("negative retain")
	}
}
func TestConcurrentLifecycle(t *testing.T) {
	b, _ := New(32)
	var wg sync.WaitGroup
	for worker := 0; worker < 12; worker++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			for i := 0; i < 150; i++ {
				switch worker % 3 {
				case 0:
					b.Publish("events", []byte("payload"))
				case 1:
					s, e := b.Subscribe("events", 0, 64)
					if e == nil {
						_ = s.Err()
						s.Cancel()
						_ = s.Err()
					}
				case 2:
					s, e := b.Subscribe(fmt.Sprint(worker, i), 0, 2)
					if e == nil {
						b.Publish(fmt.Sprint(worker, i), nil)
						s.Cancel()
						for range s.C {
						}
						_ = s.Err()
					}
				}
			}
		}(worker)
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < 30; i++ {
			b.Close()
		}
	}()
	wg.Wait()
	b.Close()
}
func TestAtomicReplayJoin(t *testing.T) {
	b, _ := New(2048)
	defer b.Close()
	start := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		<-start
		for i := 0; i < 1000; i++ {
			b.Publish("t", []byte("x"))
		}
	}()
	close(start)
	s, err := b.Subscribe("t", 0, 2048)
	if err != nil {
		t.Fatal(err)
	}
	<-done
	s.Cancel()
	var n uint64
	for m := range s.C {
		n++
		if m.Sequence != n {
			t.Fatalf("gap: %d after %d", m.Sequence, n-1)
		}
	}
	if n != 1000 {
		t.Fatalf("lost messages %d", n)
	}
}
