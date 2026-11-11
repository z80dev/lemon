package batch

import "example.com/go_shared_settings/internal/config"

func Load(text string) (config.Settings, error) { return config.Parse(text) }
