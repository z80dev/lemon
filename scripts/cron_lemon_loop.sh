#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

TS="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
RUN_DIR="docs/agent-loop/runs"
mkdir -p "$RUN_DIR"

# Best-effort cleanup from previously killed runs (stale tmux sockets)
# Avoids accumulating /tmp/lemon-tmux-*.sock files and wedged tmux servers.
if command -v tmux >/dev/null 2>&1; then
  for sock in /tmp/lemon-tmux-*.sock; do
    [ -S "$sock" ] || continue
    # If the server is dead, tmux will error; ignore.
    tmux -S "$sock" kill-server 2>/dev/null || true
    rm -f "$sock" 2>/dev/null || true
  done
fi


CODEX_OUT="$RUN_DIR/${TS}-codex.md"
CLAUDE_OUT="$RUN_DIR/${TS}-claude.md"
DIFF_OUT="$RUN_DIR/${TS}-diff.patch"

run_with_timeout() {
  # Usage: run_with_timeout <seconds> <outfile> <command...>
  local seconds="$1"; shift
  local outfile="$1"; shift

  python3 - "$seconds" "$outfile" "$@" <<'PY'
import subprocess, sys, time

timeout_s = int(sys.argv[1])
outfile = sys.argv[2]
cmd = sys.argv[3:]

start = time.time()
with open(outfile, 'a', encoding='utf-8', errors='ignore') as f:
    f.write(f"\n---\nCommand: {' '.join(cmd)}\nStarted: {time.strftime('%Y-%m-%d %H:%M:%SZ', time.gmtime())}\nTimeout: {timeout_s}s\n---\n")
    f.flush()
    try:
        p = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, text=True, timeout=timeout_s)
        f.write(f"\n---\nExit: {p.returncode}\nDuration: {time.time()-start:.1f}s\n---\n")
    except subprocess.TimeoutExpired:
        f.write(f"\n---\nTIMEOUT after {timeout_s}s\nDuration: {time.time()-start:.1f}s\n---\n")
        sys.exit(124)
PY
}

# --- 1) Codex: review + plan ---
cat > "$CODEX_OUT" <<'EOF'
# Codex review/plan

EOF

CODEX_PROMPT=$'You are working in the Lemon repo (Elixir/BEAM agent harness).\n\nTasks:\n1) Review architecture quickly (module boundaries + extensibility).\n2) Propose 3–7 concrete next improvements toward a fully featured agent harness (Pi/OpenCode-ish), prioritizing a backend plugin system.\n3) Choose ONE smallest-scope, highest-leverage change implementable in <= 20 minutes.\n4) Output markdown with these sections EXACTLY (and do not add extra headings):\n\n## Findings\n- ...\n\n## Proposed next steps (prioritized)\n1. ...\n\n## Chosen task for this run\n...\n\n## Acceptance criteria\n- ...\n\nBe concise; avoid big refactors.'

# NOTE: `codex --yolo` is interactive/TUI and does not terminate reliably in non-interactive cron runs.
# For cron we use the equivalent non-interactive mode:
#   codex exec --dangerously-bypass-approvals-and-sandbox
# 12 min budget for Codex planning
run_with_timeout 720 "$CODEX_OUT" codex exec --dangerously-bypass-approvals-and-sandbox "$CODEX_PROMPT" || true

# Extract chosen task (best effort) — pick the LAST occurrence
CHOSEN_TASK="$(python3 - <<PY
import re
lines=open('$CODEX_OUT','r',encoding='utf-8',errors='ignore').read().splitlines()
idxs=[i for i,l in enumerate(lines) if re.match(r'^##\s*Chosen task for this run\s*$', l.strip(), re.I)]
chosen=None
if idxs:
    i=idxs[-1]
    for j in range(i+1, min(i+50, len(lines))):
        t=lines[j].strip()
        if not t: 
            continue
        if t.startswith('---') or t.lower().startswith('command:'):
            continue
        # stop if we hit another heading
        if re.match(r'^##\s+', t):
            break
        chosen=t.lstrip('-* ').strip()
        break
print(chosen or "(see codex output)")
PY
)"

# --- 2) Claude: implement ---
cat > "$CLAUDE_OUT" <<EOF
# Claude implementation

Chosen task (from Codex): $CHOSEN_TASK

EOF

# Save diff before
git diff > /tmp/lemon-pre.diff 2>/dev/null || true

read -r -d '' CLAUDE_PROMPT <<EOF || true
Implement the chosen task from the latest Codex run.

Chosen task: $CHOSEN_TASK

Instructions:
- If the chosen task is unclear, implement a small, safe scaffolding step toward a backend plugin system (behaviours/interfaces + minimal example).
- Keep changes small (no big refactors).
- Update docs/tests as appropriate.

At the end, output markdown:
## Summary
## Files touched
## How to verify
## Next step
EOF

# z80 requested: --dangerously-skip-permissions
# Claude appears to require a real PTY to run reliably here.
# Run Claude inside tmux (Option B), then capture the pane output to $CLAUDE_OUT.
run_claude_tmux() {
  local out="$1"; shift
  local prompt="$1"; shift

  local sock="/tmp/lemon-tmux-${TS}.sock"
  local session="lemon-${TS}"
  local token="LEMON_DONE_${TS}"
  local prompt_file="/tmp/lemon-claude-prompt-${TS}.txt"

  printf "%s" "$prompt" > "$prompt_file"

  # Fresh server per run
  tmux -S "$sock" kill-server 2>/dev/null || true
  tmux -S "$sock" new-session -d -s "$session" "bash"

  # Run Claude, then signal completion via tmux wait-for.
  # Read prompt from file to avoid quoting hell.
  tmux -S "$sock" send-keys -t "$session" "PROMPT=\"\$(cat '$prompt_file')\"; claude --dangerously-skip-permissions -p \"\$PROMPT\"; EC=\$?; echo; echo \"__LEMON_CLAUDE_EXIT:\$EC__\"; tmux -S '$sock' wait-for -S '$token'" Enter

  # Wait for completion and capture output regardless (18 minutes)
  python3 - "$sock" "$token" "$session" "$out" <<'PY' || true
import subprocess, sys, time
sock, token, session, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
start=time.time()
timeout=1080
try:
    subprocess.run(["tmux","-S",sock,"wait-for",token], timeout=timeout, check=False)
except subprocess.TimeoutExpired:
    pass
cap = subprocess.run(["tmux","-S",sock,"capture-pane","-p","-t",f"{session}:0.0"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
with open(out,'a',encoding='utf-8',errors='ignore') as f:
    f.write("\n---\nTMUX CAPTURE\n---\n")
    f.write(cap.stdout)
    f.write(f"\n---\nDuration: {time.time()-start:.1f}s\n---\n")
PY

  tmux -S "$sock" kill-server 2>/dev/null || true
  rm -f "$prompt_file" 2>/dev/null || true
}

# 18 min budget for implementation.
run_claude_tmux "$CLAUDE_OUT" "$CLAUDE_PROMPT" || true

# Save diff
git diff > "$DIFF_OUT" 2>/dev/null || true

# Append to run log
{
  echo "## $TS";
  echo "- Codex: $CODEX_OUT";
  echo "- Claude: $CLAUDE_OUT";
  echo "- Diff: $DIFF_OUT";
  echo;
} >> docs/agent-loop/RUN_LOG.md

# Print a short summary to stdout (cron delivery uses this)
echo "Lemon loop run $TS"
echo "Chosen task: $CHOSEN_TASK"
echo "Codex output: $CODEX_OUT"
echo "Claude output: $CLAUDE_OUT"
echo "Diff: $DIFF_OUT"