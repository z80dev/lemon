package windows

import (
	"errors"
	"math"
	"reflect"
	"testing"
)

func TestContract(t *testing.T) {
	cases := []struct{ in, want []Window }{
		{nil, nil}, {[]Window{}, nil},
		{[]Window{{9, 12}, {1, 5}, {5, 9}, {2, 3}}, []Window{{1, 12}}},
		{[]Window{{1, 20}, {2, 3}, {21, 22}}, []Window{{1, 20}, {21, 22}}},
		{[]Window{{math.MaxInt64 - 1, math.MaxInt64}, {math.MinInt64, math.MinInt64 + 1}}, []Window{{math.MinInt64, math.MinInt64 + 1}, {math.MaxInt64 - 1, math.MaxInt64}}},
	}
	for _, c := range cases {
		before := append([]Window(nil), c.in...)
		got, err := Normalize(c.in)
		if err != nil || !reflect.DeepEqual(got, c.want) {
			t.Fatalf("%v -> %v %v want %v", c.in, got, err, c.want)
		}
		if len(c.in) > 0 && !reflect.DeepEqual(c.in, before) {
			t.Fatal("input changed")
		}
		if len(got) > 0 {
			got[0].Start = 77
			if !reflect.DeepEqual(c.in, before) {
				t.Fatal("result aliases input")
			}
		}
	}
	for _, in := range [][]Window{{{2, 2}}, {{5, 4}}, {{1, 3}, {8, 7}}, {{math.MaxInt64, math.MinInt64}}} {
		got, err := Normalize(in)
		if got != nil || !errors.Is(err, ErrInvalid) {
			t.Fatalf("invalid %v accepted: %v %v", in, got, err)
		}
	}
}
