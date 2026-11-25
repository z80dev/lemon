defmodule Mix.Tasks.Lemon.EvalTest do
  # Deterministic and offline: these run in the fast lane. The task raises when
  # any check fails, so a broken harness or task turns this file red.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Eval

  @deterministic_checks ~w(deterministic_contract statistical_stability read_edit_workflow)

  setup do
    Mix.Task.run("app.start", ["--quiet"])
    :ok
  end

  describe "run/1" do
    test "with no options passes every deterministic check and prints a human report" do
      output = capture_io(fn -> Eval.run([]) end)

      assert [_, passed] = Regex.run(~r/^Eval summary: (\d+) passed, 0 failed$/m, output)
      assert String.to_integer(passed) >= length(@deterministic_checks)

      for name <- @deterministic_checks do
        assert output =~ "- #{name}: pass"
      end
    end

    test "--json reports every check with details and consistent counts" do
      report = run_json(["--iterations", "2", "--json"])

      assert %{"summary" => %{"passed" => passed, "failed" => 0}, "results" => results} = report
      assert passed == length(results)
      assert Enum.all?(results, &(&1["status"] == "pass"))
      assert Enum.all?(results, &(is_map(&1["details"]) and map_size(&1["details"]) > 0))

      names = Enum.map(results, & &1["name"])
      assert Enum.all?(@deterministic_checks, &(&1 in names))
      assert statistical_iterations(report) == 2
    end

    test "-n sets the statistical iteration count and --cwd is accepted" do
      report = run_json(["-n", "3", "--cwd", File.cwd!(), "--json"])

      assert report["summary"]["failed"] == 0
      assert statistical_iterations(report) == 3
    end

    test "raises on real failing checks when live credentials are missing" do
      env_vars =
        ~w(LEMON_EVAL_API_KEY LEMON_EVAL_API_KEY_SECRET INTEGRATION_API_KEY INTEGRATION_API_KEY_SECRET ANTHROPIC_API_KEY)

      previous = Map.new(env_vars, &{&1, System.get_env(&1)})
      Enum.each(env_vars, &System.delete_env/1)

      on_exit(fn ->
        Enum.each(previous, fn
          {key, nil} -> System.delete_env(key)
          {key, value} -> System.put_env(key, value)
        end)
      end)

      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/^Eval harness failed \(\d+ failing checks\)\.$/, fn ->
            Eval.run(["--iterations", "1", "--live-model", "--json"])
          end
        end)

      report = Jason.decode!(output)
      assert report["summary"]["failed"] > 0

      assert %{"status" => "fail", "details" => %{"reason" => reason}} =
               Enum.find(report["results"], &(&1["name"] == "live_model_memory_trace_contract"))

      assert reason =~ "LEMON_EVAL_API_KEY"
    end
  end

  describe "command parsing" do
    test "rejects unknown options" do
      assert_raise Mix.Error, ~r/Invalid eval option/, fn ->
        Eval.run(["--iterations", "2", "--unknown-flag"])
      end
    end

    test "rejects invalid iteration count" do
      assert_raise Mix.Error, ~r/Invalid eval option/, fn ->
        Eval.run(["--iterations", "not_a_number"])
      end
    end

    test "rejects non-positive iteration count" do
      assert_raise Mix.Error, ~r/--iterations must be a positive integer/, fn ->
        Eval.run(["--iterations", "0"])
      end
    end
  end

  defp run_json(args) do
    Jason.decode!(capture_io(fn -> Eval.run(args) end))
  end

  defp statistical_iterations(report) do
    report["results"]
    |> Enum.find(&(&1["name"] == "statistical_stability"))
    |> get_in(["details", "iterations"])
  end
end
