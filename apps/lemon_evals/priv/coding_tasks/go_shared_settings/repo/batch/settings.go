package batch

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

type Settings struct {
	Workers int
	Timeout time.Duration
}

func Load(text string) (Settings, error) { return parse(text) }
func parse(text string) (Settings, error) {
	cfg := Settings{Workers: 4, Timeout: 5 * time.Second}
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		kv := strings.SplitN(line, "=", 2)
		if len(kv) != 2 {
			return Settings{}, fmt.Errorf("bad setting")
		}
		switch strings.TrimSpace(kv[0]) {
		case "workers":
			n, err := strconv.Atoi(strings.TrimSpace(kv[1]))
			if err != nil {
				return Settings{}, err
			}
			cfg.Workers = n
		case "timeout":
			d, err := time.ParseDuration(strings.TrimSpace(kv[1]))
			if err != nil {
				return Settings{}, err
			}
			cfg.Timeout = d
		default:
			return Settings{}, fmt.Errorf("unknown setting")
		}
	}
	return cfg, nil
}
