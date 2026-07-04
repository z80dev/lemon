defmodule LemonSimUi.LeaderboardLiveTest do
  use LemonSimUi.ConnCase

  @moduletag :tmp_dir

  test "renders suite rankings and skips malformed suite files", %{conn: conn, tmp_dir: tmp_dir} do
    original_roots = Application.get_env(:lemon_sim_ui, :suite_roots)
    Application.put_env(:lemon_sim_ui, :suite_roots, [tmp_dir])

    on_exit(fn ->
      restore_suite_roots(original_roots)
    end)

    suite_dir = Path.join(tmp_dir, "vending-ci")
    File.mkdir_p!(suite_dir)
    File.write!(Path.join(suite_dir, "suite.json"), Jason.encode!(suite_json(), pretty: true))

    malformed_dir = Path.join(tmp_dir, "bad-json")
    File.mkdir_p!(malformed_dir)
    File.write!(Path.join(malformed_dir, "suite.json"), "{not json")

    # Schema-tagged but shape-broken: competitors as strings instead of maps.
    # Must skip this one suite, not crash the whole page.
    shape_broken_dir = Path.join(tmp_dir, "shape-broken")
    File.mkdir_p!(shape_broken_dir)

    File.write!(
      Path.join(shape_broken_dir, "suite.json"),
      Jason.encode!(%{
        "schema_version" => "lemon_sim.suite.v1",
        "spec" => %{"scenario" => "shape_broken_scenario", "competitors" => ["not-a-map"]}
      })
    )

    {:ok, view, html} = live(conn, "/leaderboards")

    assert html =~ "Leaderboards"
    assert html =~ "vending_bench"
    assert html =~ "baseline"
    assert html =~ "782.4 (n=1)"
    assert html =~ "740.0 ± 3.5 (n=2)"
    assert html =~ "1,500"
    assert html =~ "$0.12"
    assert html =~ "Reported Not Ranked"
    assert html =~ "hash_mismatch"
    refute html =~ "bad-json"
    refute html =~ "shape_broken_scenario"

    # The public page must not leak absolute artifact paths.
    refute html =~ tmp_dir

    [suite_id] = Regex.run(~r/phx-value-id="([^"]+)"/, html, capture: :all_but_first)
    refute suite_id =~ "/"

    html = render_click(view, "select_suite", %{"id" => suite_id})
    assert html =~ "baseline"
    assert html =~ "pressure"
    assert html =~ "—"

    # Deep link by suite id survives a fresh mount.
    {:ok, _view, html} = live(conn, "/leaderboards?suite=#{suite_id}")
    assert html =~ "baseline"
  end

  test "renders direct suite root", %{conn: conn, tmp_dir: tmp_dir} do
    original_roots = Application.get_env(:lemon_sim_ui, :suite_roots)
    Application.put_env(:lemon_sim_ui, :suite_roots, [tmp_dir])

    on_exit(fn ->
      restore_suite_roots(original_roots)
    end)

    File.write!(Path.join(tmp_dir, "suite.json"), Jason.encode!(suite_json(), pretty: true))

    {:ok, _view, html} = live(conn, "/leaderboards")
    assert html =~ "vending_bench"
    assert html =~ "baseline"
  end

  test "renders legacy suite rankings without stats", %{conn: conn, tmp_dir: tmp_dir} do
    original_roots = Application.get_env(:lemon_sim_ui, :suite_roots)
    Application.put_env(:lemon_sim_ui, :suite_roots, [tmp_dir])

    on_exit(fn ->
      restore_suite_roots(original_roots)
    end)

    File.write!(
      Path.join(tmp_dir, "suite.json"),
      Jason.encode!(legacy_suite_json(), pretty: true)
    )

    {:ok, _view, html} = live(conn, "/leaderboards")
    assert html =~ "vending_bench"
    assert html =~ "baseline"
    assert html =~ "782.4 (n=1)"
  end

  defp suite_json do
    %{
      "schema_version" => "lemon_sim.suite.v1",
      "metadata" => %{"created_at" => "2026-07-04T12:00:00Z"},
      "spec" => %{
        "scenario" => "vending_bench",
        "preset" => "ci",
        "seeds" => [7, 8],
        "competitors" => [
          %{"id" => "baseline", "offline_strategy" => "baseline"},
          %{"id" => "pressure", "offline_strategy" => "pressure"}
        ]
      },
      "primary_metric" => %{
        "key" => ["score_modes", "v1_net_worth"],
        "name" => "score_modes.v1_net_worth",
        "direction" => "maximize"
      },
      "runs" => [
        %{
          "index" => 0,
          "scenario" => "vending_bench",
          "competitor" => "baseline",
          "competitor_spec" => %{"id" => "baseline", "offline_strategy" => "baseline"},
          "seed" => 7,
          "sim_id" => "suite_vending_bench_baseline_7",
          "artifact_dir" => "runs/baseline/7",
          "verified" => true,
          "metric" => 782.4,
          "usage_totals" => %{
            "input_tokens" => 1_000,
            "output_tokens" => 500,
            "cache_read_tokens" => 0,
            "cache_write_tokens" => 0,
            "decisions" => 10,
            "cost_usd" => 0.12
          }
        },
        %{
          "index" => 1,
          "scenario" => "vending_bench",
          "competitor" => "pressure",
          "competitor_spec" => %{"id" => "pressure", "offline_strategy" => "pressure"},
          "seed" => 8,
          "sim_id" => "suite_vending_bench_pressure_8",
          "artifact_dir" => "runs/pressure/8",
          "verified" => false,
          "metric" => nil,
          "usage_totals" => %{
            "input_tokens" => 0,
            "output_tokens" => 0,
            "cache_read_tokens" => 0,
            "cache_write_tokens" => 0,
            "decisions" => 0,
            "cost_usd" => nil
          },
          "error" => "{:hash_mismatch, \"scorecard.json\"}"
        }
      ],
      "rankings" => [
        %{
          "rank" => 1,
          "competitor" => "baseline",
          "mean" => 782.4,
          "min" => 782.4,
          "max" => 782.4,
          "stats" => %{"n" => 1, "mean" => 782.4, "std" => nil, "min" => 782.4, "max" => 782.4},
          "values_by_seed" => %{"7" => 782.4},
          "usage_totals" => %{
            "input_tokens" => 1_000,
            "output_tokens" => 500,
            "cache_read_tokens" => 0,
            "cache_write_tokens" => 0,
            "decisions" => 10,
            "cost_usd" => 0.12
          },
          "included_runs" => 1,
          "failed_runs" => 0
        },
        %{
          "rank" => 2,
          "competitor" => "pressure",
          "mean" => 740.0,
          "min" => 740.0,
          "max" => 740.0,
          "stats" => %{"n" => 2, "mean" => 740.0, "std" => 3.5, "min" => 736.5, "max" => 743.5},
          "values_by_seed" => %{"7" => 740.0},
          "usage_totals" => %{
            "input_tokens" => 20,
            "output_tokens" => 30,
            "cache_read_tokens" => 0,
            "cache_write_tokens" => 0,
            "decisions" => 1,
            "cost_usd" => nil
          },
          "included_runs" => 1,
          "failed_runs" => 1
        }
      ],
      "failures" => [
        %{
          "competitor" => "pressure",
          "seed" => 8,
          "artifact_dir" => "runs/pressure/8",
          "error" => "{:hash_mismatch, \"scorecard.json\"}"
        }
      ]
    }
  end

  defp legacy_suite_json do
    update_in(suite_json(), ["rankings"], fn rankings ->
      Enum.map(rankings, &Map.delete(&1, "stats"))
    end)
  end

  defp restore_suite_roots(nil), do: Application.delete_env(:lemon_sim_ui, :suite_roots)
  defp restore_suite_roots(roots), do: Application.put_env(:lemon_sim_ui, :suite_roots, roots)
end
