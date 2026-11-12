package batch

import "fmt"

func Describe(cfg Settings) string { return fmt.Sprintf("%d workers / %s", cfg.Workers, cfg.Timeout) }
