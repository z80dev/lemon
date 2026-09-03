defmodule LemonAutomation.SynthesisRunnerTest do
  # async: false — runner state and metric rows live in the shared LemonCore.Store.
  use ExUnit.Case, async: false

  alias LemonAutomation.SynthesisMetrics
  alias LemonAutomation.SynthesisRunner

  @hour_ms 3_600_000

  defmodule StubPipeline do
    @moduledoc false
    def run(scope, scope_key, opts) do
      send(Process.get(:test_pid), {:pipeline_run, scope, scope_key, opts})
      Process.get(:pipeline_result, {:ok, empty_result()})
    end

    def empty_result do
      %{generated: [], skipped: [], total_candidates: 0, latest_doc_ms: nil}
    end
  end

  defmodule RaisingPipeline do
    @moduledoc false
    def run(_scope, _scope_key, _opts), do: raise("pipeline exploded")
  end

  defmodule ExitingPipeline do
    @moduledoc false
    def run(_scope, _scope_key, _opts), do: exit(:boom)
  end

  setup do
    Process.put(:test_pid, self())
    agent_id = "synrun-agent-#{System.unique_integer([:positive])}"
    SynthesisMetrics.clear()

    on_exit(fn ->
      SynthesisRunner.delete_state(agent_id)
      SynthesisMetrics.clear()
    end)

    {:ok, agent_id: agent_id}
  end

  defp opts(agent_id, extra) do
    Keyword.merge(
      [enabled: true, agent_id: agent_id, pipeline_mod: StubPipeline],
      extra
    )
  end

  defp result(overrides) do
    Map.merge(StubPipeline.empty_result(), Map.new(overrides))
  end

  describe "gating" do
    test "disabled config skips", %{agent_id: agent_id} do
      assert {:skip, :disabled} = SynthesisRunner.run_once(opts(agent_id, enabled: false))
      refute_received {:pipeline_run, _, _, _}
    end

    test "an unloadable pipeline module skips", %{agent_id: agent_id} do
      assert {:skip, :pipeline_unavailable} =
               SynthesisRunner.run_once(opts(agent_id, pipeline_mod: NoSuch.Pipeline.Module))
    end

    test "active sessions block the scheduled path" do
      assert SynthesisRunner.active_sessions?(active_sessions_fun: fn -> [:a_session] end)
      refute SynthesisRunner.active_sessions?(active_sessions_fun: fn -> [] end)
      assert SynthesisRunner.active_sessions?(active_sessions_fun: fn -> raise "boom" end)
    end
  end

  describe "successful passes" do
    test "invokes the pipeline with opt_in and the stored watermark", %{agent_id: agent_id} do
      SynthesisRunner.put_state(agent_id, %{watermark_ms: 500, last_run_at_ms: nil})

      Process.put(
        :pipeline_result,
        {:ok, result(total_candidates: 2, generated: ["a", "b"], latest_doc_ms: 900)}
      )

      assert {:ok, run_result} =
               SynthesisRunner.run_once(
                 opts(agent_id, max_docs: 12, global: false, cwd: "/tmp/x")
               )

      assert_received {:pipeline_run, :agent, ^agent_id, run_opts}
      assert Keyword.get(run_opts, :opt_in) == true
      assert Keyword.get(run_opts, :since_ms) == 500
      assert Keyword.get(run_opts, :max_docs) == 12
      assert Keyword.get(run_opts, :global) == false
      assert Keyword.get(run_opts, :cwd) == "/tmp/x"

      assert run_result.watermark_ms == 900

      state = SynthesisRunner.get_state(agent_id)
      assert state.watermark_ms == 900
      assert is_integer(state.last_run_at_ms)
    end

    test "records a metrics row when candidates were examined", %{agent_id: agent_id} do
      Process.put(
        :pipeline_result,
        {:ok,
         result(
           total_candidates: 3,
           generated: ["a"],
           skipped: [{"b", :blocked_by_audit}, {"c", :already_exists}],
           latest_doc_ms: 100
         )}
      )

      assert {:ok, _} = SynthesisRunner.run_once(opts(agent_id, []))

      assert [row] = SynthesisMetrics.list()
      assert row.agent_id == agent_id
      assert row.total_candidates == 3
      assert row.generated == 1
      assert row.blocked_by_audit == 1
      assert row.skipped_other == 1
    end

    test "a zero-candidate pass records nothing and leaves the watermark alone", %{
      agent_id: agent_id
    } do
      SynthesisRunner.put_state(agent_id, %{watermark_ms: 700, last_run_at_ms: nil})
      Process.put(:pipeline_result, {:ok, result(total_candidates: 0, latest_doc_ms: nil)})

      assert {:ok, run_result} = SynthesisRunner.run_once(opts(agent_id, []))
      assert run_result.watermark_ms == 700

      assert SynthesisMetrics.list() == []
      assert SynthesisRunner.get_state(agent_id).watermark_ms == 700
    end

    test "the watermark never moves backwards", %{agent_id: agent_id} do
      SynthesisRunner.put_state(agent_id, %{watermark_ms: 900, last_run_at_ms: nil})
      Process.put(:pipeline_result, {:ok, result(total_candidates: 0, latest_doc_ms: 100)})

      assert {:ok, run_result} = SynthesisRunner.run_once(opts(agent_id, []))
      assert run_result.watermark_ms == 900
    end
  end

  describe "failure handling" do
    test "feature_disabled stamps the attempt but keeps the watermark", %{agent_id: agent_id} do
      SynthesisRunner.put_state(agent_id, %{watermark_ms: 400, last_run_at_ms: nil})
      Process.put(:pipeline_result, {:error, :feature_disabled})

      assert {:skip, :feature_disabled} = SynthesisRunner.run_once(opts(agent_id, []))

      state = SynthesisRunner.get_state(agent_id)
      assert state.watermark_ms == 400
      assert is_integer(state.last_run_at_ms)
      assert SynthesisMetrics.list() == []
    end

    test "a pipeline error is surfaced and does not advance the watermark", %{agent_id: agent_id} do
      SynthesisRunner.put_state(agent_id, %{watermark_ms: 400, last_run_at_ms: nil})
      Process.put(:pipeline_result, {:error, :store_unavailable})

      assert {:error, :store_unavailable} = SynthesisRunner.run_once(opts(agent_id, []))

      state = SynthesisRunner.get_state(agent_id)
      assert state.watermark_ms == 400
      assert is_integer(state.last_run_at_ms)
    end

    test "a raising pipeline still stamps the attempt so it cannot hot-loop", %{
      agent_id: agent_id
    } do
      SynthesisRunner.put_state(agent_id, %{watermark_ms: 400, last_run_at_ms: 123})
      now = 10 * @hour_ms

      assert {:error, message} =
               SynthesisRunner.run_once(
                 opts(agent_id, pipeline_mod: RaisingPipeline, now_ms: now)
               )

      assert message =~ "pipeline exploded"

      state = SynthesisRunner.get_state(agent_id)
      # Watermark untouched — nothing is skipped once the pipeline recovers.
      assert state.watermark_ms == 400
      # ...but the attempt is stamped, so the 60s manager tick honors the interval.
      assert state.last_run_at_ms == now

      refute SynthesisRunner.should_run_now?(
               opts(agent_id, interval_hours: 6, now_ms: now + @hour_ms)
             )
    end

    test "an exiting pipeline stamps the attempt too", %{agent_id: agent_id} do
      SynthesisRunner.put_state(agent_id, %{watermark_ms: 400, last_run_at_ms: 123})
      now = 11 * @hour_ms

      assert {:error, {:exit, :boom}} =
               SynthesisRunner.run_once(
                 opts(agent_id, pipeline_mod: ExitingPipeline, now_ms: now)
               )

      state = SynthesisRunner.get_state(agent_id)
      assert state.watermark_ms == 400
      assert state.last_run_at_ms == now
    end
  end

  describe "should_run_now?/1" do
    test "is true when nothing has run yet", %{agent_id: agent_id} do
      assert SynthesisRunner.should_run_now?(opts(agent_id, []))
    end

    test "is false while disabled", %{agent_id: agent_id} do
      refute SynthesisRunner.should_run_now?(opts(agent_id, enabled: false))
    end

    test "gates on the configured interval", %{agent_id: agent_id} do
      now = 10 * @hour_ms
      Process.put(:pipeline_result, {:ok, result(total_candidates: 0)})

      assert {:ok, _} = SynthesisRunner.run_once(opts(agent_id, now_ms: now))

      refute SynthesisRunner.should_run_now?(
               opts(agent_id, interval_hours: 6, now_ms: now + 5 * @hour_ms)
             )

      assert SynthesisRunner.should_run_now?(
               opts(agent_id, interval_hours: 6, now_ms: now + 6 * @hour_ms)
             )
    end
  end

  describe "config/1" do
    test "normalizes string keys from app env", %{agent_id: agent_id} do
      previous = Application.get_env(:lemon_automation, :synthesis_runner)

      Application.put_env(:lemon_automation, :synthesis_runner, %{
        "enabled" => true,
        "interval_hours" => 12,
        "max_docs" => 7
      })

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:lemon_automation, :synthesis_runner)
          value -> Application.put_env(:lemon_automation, :synthesis_runner, value)
        end
      end)

      cfg = SynthesisRunner.config(agent_id: agent_id)
      assert cfg[:enabled] == true
      assert cfg[:interval_hours] == 12
      assert cfg[:max_docs] == 7
      assert cfg[:agent_id] == agent_id
    end

    test "test env keeps the scheduled runner disabled by default" do
      assert SynthesisRunner.config([])[:enabled] == false
    end
  end
end
