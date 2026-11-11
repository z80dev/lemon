package windows

import "sort"

func Normalize(input []Window) ([]Window, error) {
	if len(input) == 0 {
		return nil, nil
	}
	sort.Slice(input, func(i, j int) bool { return input[i].Start < input[j].Start })
	out := []Window{input[0]}
	for _, w := range input[1:] {
		last := &out[len(out)-1]
		if w.Start < last.End {
			last.End = w.End
		} else {
			out = append(out, w)
		}
	}
	return out, nil
}
