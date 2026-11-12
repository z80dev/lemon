#!/usr/bin/env bash
set -euo pipefail
cp /verify/contract_test.go /work/contract_test.go
cd /work
GOMAXPROCS=2 GOTOOLCHAIN=local GOPROXY=off go test ./...
