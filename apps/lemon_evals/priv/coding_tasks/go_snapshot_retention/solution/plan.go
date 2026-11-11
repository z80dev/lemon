package retention

import (
	"fmt"
	"sort"
)

func Plan(snapshots []Snapshot, policy Policy) ([]string, error) {
	if policy.Keep < 0 {
		return nil, fmt.Errorf("%w: negative keep", ErrInvalid)
	}
	seen := make(map[string]bool, len(snapshots))
	groups := map[string][]Snapshot{}
	for _, s := range snapshots {
		if s.ID == "" || s.Volume == "" || seen[s.ID] {
			return nil, fmt.Errorf("%w: snapshot %q", ErrInvalid, s.ID)
		}
		seen[s.ID] = true
		if !s.Pinned {
			groups[s.Volume] = append(groups[s.Volume], s)
		}
	}
	var deleted []string
	for _, group := range groups {
		sort.Slice(group, func(i, j int) bool {
			if group[i].Created == group[j].Created {
				return group[i].ID < group[j].ID
			}
			return group[i].Created > group[j].Created
		})
		for i, s := range group {
			if i >= policy.Keep && s.Created < policy.Cutoff {
				deleted = append(deleted, s.ID)
			}
		}
	}
	sort.Strings(deleted)
	return deleted, nil
}
