package batch

import (
	"example.com/go_shared_settings/internal/config"
	"fmt"
)

func Describe(cfg config.Settings) string {
	return fmt.Sprintf("%d workers / %s", cfg.Workers, cfg.Timeout)
}
