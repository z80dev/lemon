package inventory

import (
	"fmt"
	"sort"
)

func Reconcile(opening map[string]int64, events []Event) ([]Balance, error) {
	invalid := func(reason string) ([]Balance, error) { return nil, fmt.Errorf("%w: %s", ErrInvalid, reason) }
	totals := make(map[string]int64, len(opening))
	for k, v := range opening {
		if k == "" || v < 0 {
			return invalid("opening balance")
		}
		totals[k] = v
	}
	byID := make(map[string]Event, len(events))
	for _, e := range events {
		if e.ID == "" {
			return invalid("empty ID")
		}
		if _, ok := byID[e.ID]; ok {
			return invalid("duplicate ID")
		}
		byID[e.ID] = e
		switch e.Kind {
		case "receive", "ship":
			if e.SKU == "" || e.Quantity <= 0 || e.Ref != "" {
				return invalid("movement")
			}
			if _, ok := totals[e.SKU]; !ok {
				totals[e.SKU] = 0
			}
		case "cancel":
			if e.SKU != "" || e.Quantity != 0 || e.Ref == "" {
				return invalid("cancellation")
			}
		default:
			return invalid("kind")
		}
	}
	canceled := map[string]bool{}
	for _, e := range events {
		if e.Kind != "cancel" {
			continue
		}
		target, ok := byID[e.Ref]
		if !ok || target.Kind == "cancel" || canceled[e.Ref] {
			return invalid("cancellation target")
		}
		canceled[e.Ref] = true
	}
	for _, e := range events {
		if canceled[e.ID] {
			continue
		}
		switch e.Kind {
		case "receive":
			totals[e.SKU] += e.Quantity
		case "ship":
			totals[e.SKU] -= e.Quantity
		}
	}
	var out []Balance
	for k, v := range totals {
		if v < 0 {
			return invalid("negative final stock")
		}
		out = append(out, Balance{k, v})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].SKU < out[j].SKU })
	return out, nil
}
