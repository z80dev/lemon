package server

func Ready(cfg Settings) bool { return cfg.Workers > 0 && cfg.Timeout > 0 }
