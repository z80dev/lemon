#!/usr/bin/env bash
set -euo pipefail
find "$1" -type f | sort | while read -r file; do sha256sum "$file"; done
