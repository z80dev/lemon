package batch

import "testing"

func TestLoad(t *testing.T) {
	cfg, err := Load("workers=8\ntimeout=2s")
	if err != nil || Describe(cfg) != "8 workers / 2s" {
		t.Fatalf("%v %v", cfg, err)
	}
}
