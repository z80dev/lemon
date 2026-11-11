package server

import "example.com/go_shared_settings/internal/config"

func Ready(cfg config.Settings) bool { return cfg.Workers > 0 && cfg.Timeout > 0 }
