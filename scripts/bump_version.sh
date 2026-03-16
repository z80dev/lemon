#!/usr/bin/env bash
# bump_version.sh — Coordinate a CalVer version bump across all packages.
#
# Usage:
#   scripts/bump_version.sh <new-version>
#   scripts/bump_version.sh --auto          # derive next version from today's date
#
# Version format: YYYY.MM.PATCH  (e.g. 2026.03.0)
# See docs/release/versioning_and_channels.md for the versioning model.
#
# Files updated:
#   mix.exs                          (umbrella version)
#   clients/lemon-tui/package.json
#   clients/lemon-browser-node/package.json
#   clients/lemon-web/package.json
#   clients/lemon-web/shared/package.json
#   clients/lemon-web/server/package.json
#   clients/lemon-web/web/package.json

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Helpers ──────────────────────────────────────────────────────────────────

usage() {
  sed -n '/^# /s/^# //p' "$0" | head -20
  exit 1
}

calver_validate() {
  local v="$1"
  if ! echo "$v" | grep -qE '^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$'; then
    echo "ERROR: '$v' is not a valid CalVer version (YYYY.MM.PATCH)." >&2
    exit 1
  fi
}

calver_auto() {
  local year month
  year=$(date +%Y)
  month=$(date +%m)       # zero-padded to match CalVer examples (2026.03.0)
  local prefix="${year}.${month}"

  # Find the highest PATCH already used for this year.month in mix.exs
  local current
  current=$(grep -E '^\s+version:' "$REPO_ROOT/mix.exs" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
  local cur_prefix cur_patch
  cur_prefix=$(echo "$current" | cut -d. -f1-2)
  cur_patch=$(echo "$current" | cut -d. -f3)

  if [ "$cur_prefix" = "$prefix" ]; then
    echo "${prefix}.$((cur_patch + 1))"
  else
    echo "${prefix}.0"
  fi
}

bump_mix() {
  local new_ver="$1"
  local file="$REPO_ROOT/mix.exs"
  local old_ver
  old_ver=$(grep -oE 'version: "[^"]+"' "$file" | grep -oE '"[^"]+"' | tr -d '"')

  if [ "$old_ver" = "$new_ver" ]; then
    echo "  mix.exs: already at $new_ver (no change)"
    return
  fi

  sed -i "s/version: \"${old_ver}\"/version: \"${new_ver}\"/" "$file"
  echo "  mix.exs: $old_ver → $new_ver"
}

bump_package_json() {
  local new_ver="$1"
  local file="$2"

  if [ ! -f "$file" ]; then
    return
  fi

  local old_ver
  old_ver=$(python3 -c "import json; d=json.load(open('$file')); print(d.get('version',''))" 2>/dev/null || echo "")

  if [ "$old_ver" = "$new_ver" ]; then
    echo "  $file: already at $new_ver (no change)"
    return
  fi

  python3 - "$file" "$new_ver" <<'PYEOF'
import json, sys
path, new_ver = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = json.load(f)
old_ver = d.get('version', '')
d['version'] = new_ver
with open(path, 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
print(f'  {path}: {old_ver} → {new_ver}')
PYEOF
}

# ── Main ─────────────────────────────────────────────────────────────────────

if [ $# -eq 0 ]; then
  usage
fi

if [ "$1" = "--auto" ]; then
  NEW_VERSION=$(calver_auto)
  echo "Auto-derived version: $NEW_VERSION"
else
  NEW_VERSION="$1"
fi

calver_validate "$NEW_VERSION"

echo "Bumping all packages to $NEW_VERSION ..."

bump_mix "$NEW_VERSION"

CLIENT_PACKAGES=(
  "clients/lemon-tui/package.json"
  "clients/lemon-browser-node/package.json"
  "clients/lemon-web/package.json"
  "clients/lemon-web/shared/package.json"
  "clients/lemon-web/server/package.json"
  "clients/lemon-web/web/package.json"
)

for rel_path in "${CLIENT_PACKAGES[@]}"; do
  bump_package_json "$NEW_VERSION" "$REPO_ROOT/$rel_path"
done

echo ""
echo "Done. Next steps:"
echo "  1. Review the diff: git diff"
echo "  2. Commit: git commit -am 'chore: bump version to $NEW_VERSION'"
echo "  3. Tag:    git tag v$NEW_VERSION"
echo "  4. Push:   git push origin main v$NEW_VERSION"
