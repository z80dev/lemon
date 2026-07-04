#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Relative OUT_DIR resolves against the repo root. The resolved path must be a
# strict descendant of the repo (and not the repo itself) because it gets
# rm -rf'd below — this blocks traversal like "../sibling" or an absolute "/".
OUT_DIR="$(realpath -m "${1:-tmp/sim_demo_bundles}")"

case "$OUT_DIR" in
  "$ROOT"/*) ;;
  *)
    echo "refusing to replace output directory outside the repo: $OUT_DIR" >&2
    exit 64
    ;;
esac

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

export LEMON_STORE_PATH="${LEMON_STORE_PATH:-$OUT_DIR/store}"
mkdir -p "$LEMON_STORE_PATH"

SCORE_DIR="$OUT_DIR/scorecards"
mkdir -p "$SCORE_DIR"

PRESSURE_DIR="$OUT_DIR/vending_bench_pressure_90d_seed42"
BASELINE_DIR="$OUT_DIR/vending_bench_baseline_90d_seed42"
ARENA_DIR="$OUT_DIR/vending_bench_arena_baseline_ci_seed42"
SUITE_DIR="$OUT_DIR/suite/vending_bench_ci"
RATINGS_DIR="$OUT_DIR/ratings"

# Trace goes to stderr so callers can redirect a run_mix invocation's stdout
# into a file (e.g. score JSON) without the trace line corrupting it.
run_mix() {
  echo "+ mix $*" >&2
  mix "$@"
}

score_file_name() {
  echo "$1" | sed 's#[^A-Za-z0-9_.-]#_#g'
}

verify_and_score() {
  local label="$1"
  local bundle_dir="$2"
  local score_file="$SCORE_DIR/$(score_file_name "$label").json"

  run_mix lemon.sim.verify "$bundle_dir"
  run_mix lemon.sim.score "$bundle_dir" >"$score_file"
  echo "scorecard: $score_file"
}

print_bundle_metric() {
  local label="$1"
  local bundle_dir="$2"

  BUNDLE_LABEL="$label" BUNDLE_DIR="$bundle_dir" mix run --no-start -e '
    label = System.fetch_env!("BUNDLE_LABEL")
    dir = System.fetch_env!("BUNDLE_DIR")
    scorecard = dir |> Path.join("scorecard.json") |> File.read!() |> Jason.decode!()

    metric =
      cond do
        is_map(scorecard["score_modes"]) ->
          "score_modes.v1_net_worth=#{get_in(scorecard, ["score_modes", "v1_net_worth"])}"

        is_list(scorecard["leaderboard"]) ->
          top = List.first(scorecard["leaderboard"]) || %{}
          "leaderboard[0].money_balance=#{top["money_balance"]}"

        true ->
          "status=#{scorecard["status"]}"
      end

    IO.puts("  - #{label}: #{dir} (#{metric})")
  '
}

print_suite_metric() {
  SUITE_DIR="$SUITE_DIR" mix run --no-start -e '
    suite_dir = System.fetch_env!("SUITE_DIR")
    suite = suite_dir |> Path.join("suite.json") |> File.read!() |> Jason.decode!()
    metric = get_in(suite, ["primary_metric", "name"])

    IO.puts("  - suite: #{suite_dir} (#{metric})")

    for ranking <- suite["rankings"] || [] do
      IO.puts("    #{ranking["competitor"]}: mean=#{ranking["mean"]}")
    end
  '
}

print_ratings_metric() {
  RATINGS_DIR="$RATINGS_DIR" mix run --no-start -e '
    ratings_dir = System.fetch_env!("RATINGS_DIR")
    ratings = ratings_dir |> Path.join("ratings.json") |> File.read!() |> Jason.decode!()
    IO.puts("  - ratings: #{ratings_dir}")

    for competitor <- ratings["competitors"] || [] do
      IO.puts("    #{competitor["competitor"]}: rating=#{competitor["rating"]}")
    end
  '
}

run_mix lemon.sim.vending_bench \
  --offline-strategy pressure \
  --max-days 90 \
  --max-turns 120 \
  --seed 42 \
  --sim-id demo_vb_pressure_90d_seed42 \
  --artifact-dir "$PRESSURE_DIR" \
  --deterministic-artifacts

run_mix lemon.sim.vending_bench \
  --offline-strategy baseline \
  --max-days 90 \
  --max-turns 120 \
  --seed 42 \
  --sim-id demo_vb_baseline_90d_seed42 \
  --artifact-dir "$BASELINE_DIR" \
  --deterministic-artifacts

run_mix lemon.sim.vending_bench \
  --arena \
  --offline-strategy baseline \
  --max-days 7 \
  --max-turns 12 \
  --arena-agents 5 \
  --seed 42 \
  --sim-id demo_vb_arena_baseline_ci_seed42 \
  --artifact-dir "$ARENA_DIR" \
  --deterministic-artifacts

run_mix lemon.sim.suite \
  --scenario vending_bench \
  --preset ci \
  --offline baseline,pressure \
  --seeds 1,2 \
  --out "$SUITE_DIR"

run_mix lemon.sim.ratings \
  --suites "$SUITE_DIR" \
  --out "$RATINGS_DIR"

declare -a bundle_labels=(
  "vending_bench_pressure_90d_seed42"
  "vending_bench_baseline_90d_seed42"
  "vending_bench_arena_baseline_ci_seed42"
)

declare -a bundle_dirs=(
  "$PRESSURE_DIR"
  "$BASELINE_DIR"
  "$ARENA_DIR"
)

while IFS= read -r manifest_path; do
  bundle_dirs+=("$(dirname "$manifest_path")")
  bundle_labels+=("suite_$(dirname "${manifest_path#$SUITE_DIR/runs/}")")
done < <(find "$SUITE_DIR/runs" -mindepth 3 -maxdepth 3 -name manifest.json | sort)

for index in "${!bundle_dirs[@]}"; do
  verify_and_score "${bundle_labels[$index]}" "${bundle_dirs[$index]}"
done

echo
echo "Demo bundle summary"
for index in 0 1 2; do
  print_bundle_metric "${bundle_labels[$index]}" "${bundle_dirs[$index]}"
done
print_suite_metric
print_ratings_metric
