package config

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

type Settings struct {
	Workers int
	Timeout time.Duration
}

var ErrInvalid = errors.New("invalid worker settings")

func Parse(text string) (Settings, error) {
	cfg := Settings{Workers: 4, Timeout: 5 * time.Second}
	seen := map[string]bool{}
	bad := func() (Settings, error) { return Settings{}, fmt.Errorf("%w", ErrInvalid) }
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		kv := strings.SplitN(line, "=", 2)
		if len(kv) != 2 {
			return bad()
		}
		key, value := strings.TrimSpace(kv[0]), strings.TrimSpace(kv[1])
		if seen[key] {
			return bad()
		}
		seen[key] = true
		switch key {
		case "workers":
			n, err := strconv.Atoi(value)
			if err != nil || n < 1 || n > 64 {
				return bad()
			}
			cfg.Workers = n
		case "timeout":
			d, err := time.ParseDuration(value)
			if err != nil || d <= 0 {
				return bad()
			}
			cfg.Timeout = d
		default:
			return bad()
		}
	}
	return cfg, nil
}
