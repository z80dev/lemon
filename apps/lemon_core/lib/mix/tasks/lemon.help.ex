defmodule Mix.Tasks.Lemon.Help do
  use Mix.Task

  @shortdoc "List all mix lemon.* tasks, grouped by purpose"

  @moduledoc """
  Print every `mix lemon.*` task grouped by purpose.

  `mix help | grep lemon` lists the ~85 Lemon tasks alphabetically with no
  grouping. This task prints the same set organized into logical groups, reading
  each task's `@shortdoc` at runtime so the descriptions never drift from the
  code.

  ## Usage

      mix lemon.help

  See `docs/mix-tasks.md` for the same grouping with flags, examples, and
  follow-up notes.
  """

  # Ordered groups of task names. Descriptions are pulled from each task's
  # @shortdoc at runtime; @fallback covers tasks that ship without one (or that
  # live outside the umbrella, like lemon.new in the installer archive).
  @groups [
    {"Onboarding & setup",
     ~w(lemon.new lemon.setup lemon.onboard lemon.onboard.anthropic lemon.onboard.codex
        lemon.onboard.copilot lemon.onboard.gemini lemon.onboard.antigravity lemon.providers
        lemon.workspace lemon.update lemon.hermes.audit lemon.hermes.migrate)},
    {"Secrets", ~w(lemon.secrets.init lemon.secrets.set lemon.secrets.list lemon.secrets.status
        lemon.secrets.check lemon.secrets.delete lemon.secrets.import_env lemon.voice.secrets)},
    {"Diagnostics & readiness",
     ~w(lemon.doctor lemon.readiness lemon.config lemon.channels lemon.usage lemon.proofs
        lemon.media lemon.models lemon.introspection lemon.feedback)},
    {"Quality & CI", ~w(lemon.quality lemon.architecture.docs lemon.check_duplicate_tests
        lemon.extension.validate lemon.cleanup lemon.eval lemon.help)},
    {"Data, stores & messaging",
     ~w(lemon.store.migrate_jsonl_to_sqlite lemon.memory lemon.policy lemon.send)},
    {"Skills", ~w(lemon.skill lemon.skill.lint)},
    {"Benchmarks (platform)", ~w(lemon.bench)},
    {"Sim: scenario runners",
     ~w(lemon.sim.auction lemon.sim.courtroom lemon.sim.diplomacy lemon.sim.dungeon_crawl
        lemon.sim.intel_network lemon.sim.legislature lemon.sim.murder_mystery lemon.sim.pandemic
        lemon.sim.poker lemon.sim.skirmish lemon.sim.space_station lemon.sim.startup_incubator
        lemon.sim.stock_market lemon.sim.supply_chain lemon.sim.survivor lemon.sim.tcg_shop
        lemon.sim.tic_tac_toe lemon.sim.vending_bench lemon.sim.werewolf)},
    {"Sim: replay renderers",
     ~w(lemon.sim.replay lemon.sim.auction_replay lemon.sim.courtroom_replay
        lemon.sim.diplomacy_replay lemon.sim.dungeon_crawl_replay lemon.sim.intel_network_replay
        lemon.sim.legislature_replay lemon.sim.murder_mystery_replay lemon.sim.pandemic_replay
        lemon.sim.poker_replay lemon.sim.space_station_replay lemon.sim.startup_incubator_replay
        lemon.sim.stock_market_replay lemon.sim.supply_chain_replay lemon.sim.survivor_replay
        lemon.sim.vending_bench_replay lemon.sim.werewolf_replay)},
    {"Sim: scoring, suites & ratings",
     ~w(lemon.sim.score lemon.sim.verify lemon.sim.suite lemon.sim.leaderboard lemon.sim.ratings)}
  ]

  @fallback %{
    "lemon.new" => "Scaffold a new Lemon agent project (installer archive)",
    "lemon.policy" => "Manage per-route model policies (channel/account/peer/thread)",
    "lemon.channels" => "Show redacted Telegram and Discord launch readiness",
    "lemon.config" => "Validate and inspect Lemon configuration",
    "lemon.proofs" => "Show redacted local proof artifact status",
    "lemon.readiness" => "Show a compact redacted launch-readiness summary",
    "lemon.usage" => "Show redacted usage, cost, token, and quota diagnostics",
    "lemon.media" => "Show redacted generated-media and provider-proof readiness",
    "lemon.skill" => "Manage Lemon skills (discover/install/update/remove)",
    "lemon.sim.leaderboard" => "Print and rewrite a suite leaderboard",
    "lemon.sim.ratings" => "Aggregate suite leaderboards into cross-suite model ratings",
    "lemon.sim.score" => "Print the scorecard for a run artifact bundle",
    "lemon.sim.suite" => "Run a benchmark suite and write a leaderboard",
    "lemon.sim.verify" => "Verify a LemonSim run artifact bundle",
    "lemon.sim.tcg_shop" => "Run the TCG Shop simulation",
    "lemon.sim.vending_bench" => "Run the Vending Bench simulation",
    "lemon.sim.vending_bench_replay" =>
      "Build a static replay browser from a VendingBench artifact dir"
  }

  @impl true
  def run(_args) do
    Mix.Task.load_all()

    count = @groups |> Enum.flat_map(fn {_t, tasks} -> tasks end) |> length()

    Mix.shell().info("Lemon mix tasks (#{count}). See docs/mix-tasks.md for flags and examples.")

    Enum.each(@groups, fn {title, tasks} ->
      Mix.shell().info("\n" <> IO.iodata_to_binary(IO.ANSI.format([:bright, title])))

      Enum.each(tasks, fn name ->
        desc = describe(name)
        Mix.shell().info("  mix " <> String.pad_trailing(name, 34) <> "  " <> desc)
      end)
    end)

    :ok
  end

  defp describe(name) do
    shortdoc(name) || Map.get(@fallback, name, "")
  end

  defp shortdoc(name) do
    case Mix.Task.get(name) do
      nil -> nil
      module -> Mix.Task.shortdoc(module)
    end
  rescue
    _ -> nil
  end
end
