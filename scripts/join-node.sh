#!/usr/bin/env bash
# Repository-owned destination enrollment; also supports bash scripts/join-node.sh.
set +x
set -euo pipefail
# Parse the complete downloaded function before doing any work.
main() {
export LC_ALL=C
fail() { printf '%s\n' "$1; enrollment was not attempted." >&2; exit 1; }
valid_authority() {
  local authority=${1#*://} port
  authority=${authority%%/*}
  [[ $authority =~ ^([A-Za-z0-9._-]+|\[[A-Fa-f0-9:]+\])(:([0-9]+))?$ ]] || return 1
  port=${BASH_REMATCH[3]}
  [[ -z $port ]] || { [[ ${#port} -le 5 ]] && (( 10#$port >= 1 && 10#$port <= 65535 )); }
}
name= controller= source= version= base_url=
while (( $# )); do
  (( $# >= 2 )) || fail 'Missing join option value'
  case "$1" in
    --name) name=$2 ;;
    --controller) controller=$2 ;;
    --source) source=$2 ;;
    --version) version=$2 ;;
    --base-url) base_url=$2 ;;
    *) fail 'Unknown join option' ;;
  esac
  shift 2
done
[[ -n $name && ${#name} -le 64 && ! $name =~ [[:cntrl:]] && $name =~ [^[:space:]] ]] || fail 'Invalid node name'
[[ ${#controller} -le 2048 && ! $controller =~ [[:space:][:cntrl:]\?\#@] && $controller =~ ^(wss://[^/]+|ws://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?)(/.*)?$ ]] || fail 'Invalid secure controller URL'
valid_authority "$controller" || fail 'Invalid controller host or port'
[[ -z $version || ( ${#version} -le 128 && $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9][A-Za-z0-9.-]*)?$ ) ]] || fail 'Invalid exact version'
if [[ -n $source ]]; then
  [[ $source == /* && ${#source} -le 4096 && ! $source =~ [[:cntrl:]] && -z $base_url ]] || fail 'Invalid destination source checkout'
else
  [[ -n $version && ${#base_url} -le 2048 && $base_url =~ ^https://[^/]+(/.*)?$ && ! $base_url =~ [[:space:][:cntrl:]\?\#@] ]] || fail 'An exact release version and HTTPS base URL are required'
  valid_authority "$base_url" || fail 'Invalid release host or port'
fi
# A controlling terminal is required even when stdin carries this script.
{ exec 3<>/dev/tty; } 2>/dev/null || fail 'A terminal is required for hidden enrollment input'
[[ -t 3 ]] || fail 'A terminal is required for hidden enrollment input'
tty_state=$(stty -g <&3) || fail 'Cannot inspect terminal settings'
installer=
cleanup() {
  stty "$tty_state" <&3 2>/dev/null || true
  unset code
  [[ -z $installer ]] || rm -f "$installer"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
stty -echo <&3 || fail 'Cannot hide enrollment input'
printf 'One-use enrollment code: ' >&3
unset code
code=
# Read bounded raw characters. A NUL delimiter yields an empty character and is
# rejected rather than silently stripped; newline terminates this single attempt.
unset character
for (( count=0; count<44; count++ )); do
  character=
  if ! IFS= read -r -d '' -n 1 character <&3; then
    printf '\n' >&3
    fail 'Enrollment input ended before a complete code'
  fi
  [[ $character == $'\n' ]] && break
  [[ $character =~ ^[A-Za-z0-9_-]$ ]] || fail 'Invalid enrollment code'
  code+=$character
done
unset character
stty "$tty_state" <&3 || fail 'Cannot restore terminal settings'
printf '\n' >&3
[[ $code =~ ^[A-Za-z0-9_-]{43}$ && $count -eq 43 ]] || fail 'Invalid enrollment code'
compatible() {
  [[ -x $1 ]] || return 1
  if [[ -n $version ]]; then
    local reported
    reported=$("$1" version 2>/dev/null) && [[ $reported == "$version" ]] || return 1
  fi
  "$1" node capabilities --json --require-bot >/dev/null 2>&1
}
if [[ -n $source ]]; then
  lemon_bin=$source/bin/lemon
  [[ -f $source/mix.exs ]] && compatible "$lemon_bin" || fail 'The configured source runtime is unavailable or incompatible'
else
  installed=$(command -v lemon 2>/dev/null || true)
  lemon_bin=$HOME/.lemon/versions/$version/bin/lemon
  if compatible "$installed"; then
    lemon_bin=$installed
  elif ! compatible "$lemon_bin"; then
    installer=$(mktemp) || fail 'Cannot prepare pinned installation'
    curl -fsSL --proto '=https' --proto-redir '=https' \
      https://raw.githubusercontent.com/z80dev/lemon/main/install.sh -o "$installer" >/dev/null 2>&1 || fail 'Cannot download the Lemon installer'
    LEMON_VERSION="$version" LEMON_INSTALL_BASE_URL="$base_url" \
      sh "$installer" --force --skip-setup --no-modify-path >/dev/null 2>&1 || fail 'The pinned Lemon installation failed'
    rm -f "$installer"
    installer=
    compatible "$lemon_bin" || fail 'The installed Lemon runtime is incompatible with the configured build'
  fi
fi
# printf is a Bash builtin: the credential never becomes a process argument or environment value.
# Exactly one enrollment attempt; uncertain outcomes must be reconciled by the owner.
printf '%s\n' "$code" | LEMON_GATEWAY_HEALTH_PORT=0 LEMON_ROUTER_HEALTH_PORT=0 \
  "$lemon_bin" node join --name "$name" --controller "$controller" --invite-code-stdin
}
main "$@"
