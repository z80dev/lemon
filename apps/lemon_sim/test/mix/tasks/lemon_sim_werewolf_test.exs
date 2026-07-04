defmodule Mix.Tasks.Lemon.Sim.WerewolfTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Lemon.Sim.Werewolf, as: WerewolfTask

  test "builds per-seat model assignments in canonical Werewolf seat order" do
    parent = self()

    runner = fn mode, opts ->
      send(parent, {:runner_called, mode, opts})
      {:ok, %{world: %{}}}
    end

    resolver = fn spec, _config -> {%{provider: :test, id: spec}, "key:#{spec}"} end

    WerewolfTask.run(
      [
        "--player-count",
        "5",
        "--models",
        "alpha,beta,gamma,delta,epsilon",
        "--seed",
        "42",
        "--sim-id",
        "ww_test",
        "--no-persist",
        "--max-turns",
        "12",
        "--artifact-dir",
        "/tmp/werewolf-task-test"
      ],
      ensure_runtime?: false,
      config_loader: fn -> :config end,
      assignment_resolver: resolver,
      runner: runner
    )

    assert_received {:runner_called, :multi, opts}
    assert opts[:player_count] == 5
    assert opts[:driver_max_turns] == 12
    assert opts[:persist?] == false
    assert opts[:seed] == 42
    assert opts[:sim_id] == "ww_test"
    assert opts[:transcript_path] == "/tmp/werewolf-task-test/ww_test.jsonl"

    assert opts[:model_assignments] == %{
             "Cora" => {%{provider: :test, id: "alpha"}, "key:alpha"},
             "Felix" => {%{provider: :test, id: "beta"}, "key:beta"},
             "Jude" => {%{provider: :test, id: "gamma"}, "key:gamma"},
             "Kira" => {%{provider: :test, id: "delta"}, "key:delta"},
             "Pia" => {%{provider: :test, id: "epsilon"}, "key:epsilon"}
           }
  end

  test "--models count must match Werewolf seat count" do
    assert_raise Mix.Error, ~r/--models expects 6 model specs/, fn ->
      WerewolfTask.run(
        ["--models", "alpha,beta"],
        ensure_runtime?: false,
        config_loader: fn -> :config end,
        assignment_resolver: fn spec, _config -> {spec, "key"} end,
        runner: fn _mode, _opts -> flunk("runner should not be called") end
      )
    end
  end

  test "--model uses the single-model Werewolf runner path" do
    parent = self()

    runner = fn mode, opts ->
      send(parent, {:runner_called, mode, opts})
      {:ok, %{world: %{}}}
    end

    model = %{provider: :test, id: "solo"}

    WerewolfTask.run(
      ["--model", "test:solo", "--player-count", "5"],
      ensure_runtime?: false,
      config_loader: fn -> :config end,
      model_resolver: fn "test:solo", :config -> model end,
      runner: runner
    )

    assert_received {:runner_called, :single, opts}
    assert opts[:model] == model
    refute Keyword.has_key?(opts, :model_assignments)
  end
end
