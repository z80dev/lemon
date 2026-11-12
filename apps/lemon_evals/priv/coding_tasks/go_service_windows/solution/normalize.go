package windows

import "sort"

func Normalize(input []Window) ([]Window, error) {
	if len(input) == 0 {
		return nil, nil
	}
	for _, w := range input {
		if w.Start >= w.End {
			return nil, ErrInvalid
		}
	}
	ordered := append([]Window(nil), input...)
	sort.Slice(ordered, func(i, j int) bool {
		if ordered[i].Start == ordered[j].Start {
			return ordered[i].End < ordered[j].End
		}
		return ordered[i].Start < ordered[j].Start
	})
	out := make([]Window, 0, len(ordered))
	for _, w := range ordered {
		if len(out) == 0 || w.Start > out[len(out)-1].End {
			out = append(out, w)
			continue
		}
		if w.End > out[len(out)-1].End {
			out[len(out)-1].End = w.End
		}
	}
	return out, nil
}
