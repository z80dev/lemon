#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BASE_TEMP="${RUNNER_TEMP:-$ROOT/tmp}"
WORK_DIR="${SIM_BENCH_WORK_DIR:-$BASE_TEMP/sim-bench-ci}"
SUITE_ROOT="$WORK_DIR/suites"
RATINGS_DIR="$WORK_DIR/ratings"
SCORES_DIR="$WORK_DIR/scores"
REPRO_ROOT="$WORK_DIR/repro"
MAX_CONCURRENCY="${SIM_BENCH_MAX_CONCURRENCY:-1}"

MODEL_CREDENTIAL_ENV_VARS=(
  AI21_API_KEY
  ANTHROPIC_API_KEY
  ANTHROPIC_TOKEN
  AZURE_OPENAI_API_KEY
  CHATGPT_TOKEN
  CLAUDE_CODE_OAUTH_TOKEN
  FIREWORKS_API_KEY
  GEMINI_API_KEY
  GOOGLE_API_KEY
  GOOGLE_GENERATIVE_AI_API_KEY
  GOOGLE_GEMINI_CLI_API_KEY
  GROQ_API_KEY
  KIMI_API_KEY
  LEMON_EVAL_API_KEY
  LEMON_EVAL_API_KEY_SECRET
  MINIMAX_API_KEY
  MISTRAL_API_KEY
  MOONSHOT_API_KEY
  NOUS_API_KEY
  OPENAI_API_KEY
  OPENAI_CODEX_API_KEY
  OPENCODE_API_KEY
  OPENROUTER_API_KEY
  XAI_API_KEY
  ZAI_API_KEY
)

log() {
  printf '\n==> %s\n' "$*"
}

clean_work_dir() {
  case "$WORK_DIR" in
    ""|"/"|"$ROOT")
      echo "Refusing unsafe SIM_BENCH_WORK_DIR: $WORK_DIR" >&2
      exit 1
      ;;
  esac

  mkdir -p "$(dirname "$WORK_DIR")"
  rm -rf "$WORK_DIR"
  mkdir -p "$SUITE_ROOT" "$RATINGS_DIR" "$SCORES_DIR" "$REPRO_ROOT"
}

scrub_model_credentials() {
  local key
  for key in "${MODEL_CREDENTIAL_ENV_VARS[@]}"; do
    unset "$key"
  done
}

run_suite() {
  local scenario="$1"
  local preset="$2"
  local seeds="$3"
  local offline="$4"
  local out="$5"

  log "Running $scenario suite"
  mix lemon.sim.suite \
    --scenario "$scenario" \
    --preset "$preset" \
    --seeds "$seeds" \
    --offline "$offline" \
    --out "$out" \
    --max-concurrency "$MAX_CONCURRENCY"

  assert_suite_clean "$out/suite.json"
  verify_and_score_runs "$out"
}

assert_suite_clean() {
  local suite_json="$1"

  SUITE_JSON="$suite_json" mix run --no-start -e '
    suite = System.fetch_env!("SUITE_JSON") |> File.read!() |> Jason.decode!()
    failures = suite["failures"] || []
    runs = suite["runs"] || []
    unverified = Enum.reject(runs, & &1["verified"])

    cond do
      failures != [] ->
        IO.inspect(failures, label: "suite failures")
        System.halt(1)

      unverified != [] ->
        IO.inspect(unverified, label: "unverified runs")
        System.halt(1)

      true ->
        IO.puts("Suite clean: #{System.fetch_env!("SUITE_JSON")}")
    end
  '
}

verify_and_score_runs() {
  local suite_dir="$1"
  local suite_name
  suite_name="$(basename "$suite_dir")"
  local score_dir="$SCORES_DIR/$suite_name"
  mkdir -p "$score_dir"

  while IFS= read -r run_dir; do
    local rel
    local score_file
    rel="${run_dir#"$suite_dir/runs/"}"
    score_file="$score_dir/${rel//\//__}.json"

    log "Verifying $suite_name/$rel"
    mix lemon.sim.verify "$run_dir"

    log "Scoring $suite_name/$rel"
    mix lemon.sim.score "$run_dir" | tee "$score_file"
  done < <(find "$suite_dir/runs" -mindepth 2 -maxdepth 2 -type d | sort)
}

run_ratings() {
  local suites_csv="$1"

  log "Running cross-suite ratings"
  mix lemon.sim.ratings --suites "$suites_csv" --out "$RATINGS_DIR"
}

run_determinism_gate() {
  local dir_a="$REPRO_ROOT/vending_baseline_a"
  local dir_b="$REPRO_ROOT/vending_baseline_b"

  log "Running VendingBench byte-determinism gate"
  mix lemon.sim.vending_bench \
    --preset ci \
    --offline-strategy baseline \
    --seed 1 \
    --sim-id vb_ci_repro \
    --deterministic-artifacts \
    --artifact-dir "$dir_a"

  mix lemon.sim.vending_bench \
    --preset ci \
    --offline-strategy baseline \
    --seed 1 \
    --sim-id vb_ci_repro \
    --deterministic-artifacts \
    --artifact-dir "$dir_b"

  diff -r "$dir_a" "$dir_b"
  log "Byte-determinism gate passed"
}

run_arena_determinism_gate() {
  local dir_a="$REPRO_ROOT/arena_baseline_a"
  local dir_b="$REPRO_ROOT/arena_baseline_b"

  log "Running VendingBench arena byte-determinism gate"
  mix lemon.sim.vending_bench \
    --preset ci \
    --arena \
    --offline-strategy baseline \
    --seed 1 \
    --sim-id vb_arena_ci_repro \
    --deterministic-artifacts \
    --artifact-dir "$dir_a"

  mix lemon.sim.vending_bench \
    --preset ci \
    --arena \
    --offline-strategy baseline \
    --seed 1 \
    --sim-id vb_arena_ci_repro \
    --deterministic-artifacts \
    --artifact-dir "$dir_b"

  diff -r "$dir_a" "$dir_b"
  log "Arena byte-determinism gate passed"
}

clean_work_dir
scrub_model_credentials

VB_SUITE="$SUITE_ROOT/vending_bench"
ARENA_SUITE="$SUITE_ROOT/vending_bench_arena"
TCG_SUITE="$SUITE_ROOT/tcg_shop"

run_suite "vending_bench" "ci" "1,2" "baseline,pressure" "$VB_SUITE"
run_suite "vending_bench_arena" "ci" "1,2" "baseline" "$ARENA_SUITE"
run_suite "tcg_shop" "ci" "1,2" "baseline,pressure,overextended" "$TCG_SUITE"
run_ratings "$VB_SUITE,$ARENA_SUITE,$TCG_SUITE"
run_determinism_gate
run_arena_determinism_gate

log "Simulation benchmark artifacts written to $WORK_DIR"
