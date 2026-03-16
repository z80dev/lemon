defmodule LemonCore.MemoryIngestTest do
  @moduledoc """
  Tests for LemonCore.MemoryIngest — focusing on J6: config must be loaded
  exactly once per ingest call, not once per feature-flag check.
  """

  use ExUnit.Case, async: false

  alias LemonCore.MemoryIngest

  @moduletag :tmp_dir

  defp make_ingest_args do
    run_id = "run_ingest_test_#{:erlang.unique_integer([:positive])}"

    record = %{
      events: [],
      started_at: System.system_time(:millisecond)
    }

    summary = %{
      session_key: "agent:ingest_test:main",
      agent_id: "ingest_test",
      prompt: "implement the feature",
      completed: %{ok: true, answer: "Done."},
      provider: "anthropic",
      model: "claude-sonnet-4-6"
    }

    {run_id, record, summary}
  end

  describe "J6: config loaded exactly once per ingest" do
    test "public ingest path loads config exactly once", %{tmp_dir: tmp_dir} do
      counter = :counters.new(1, [:atomics])

      {:ok, pid, _memory_store, _routing_feedback_store} =
        start_isolated_ingest(tmp_dir, counter, %{})

      {run_id, record, summary} = make_ingest_args()

      MemoryIngest.ingest(pid, run_id, record, summary)
      :sys.get_state(pid)

      loads = :counters.get(counter, 1)

      assert loads == 1,
             "expected config to be loaded exactly once per ingest, got #{loads} loads"

      stop_if_alive(pid)
    end

    test "config is loaded once even when both session_search and routing_feedback are enabled",
         %{tmp_dir: tmp_dir} do
      counter = :counters.new(1, [:atomics])

      {:ok, pid, _memory_store, _routing_feedback_store} =
        start_isolated_ingest(tmp_dir, counter, %{session_search: true, routing_feedback: true})

      {run_id, record, summary} = make_ingest_args()
      MemoryIngest.ingest(pid, run_id, record, summary)
      :sys.get_state(pid)

      assert :counters.get(counter, 1) == 1

      stop_if_alive(pid)
    end

    test "config is loaded once per ingest across multiple ingest calls", %{tmp_dir: tmp_dir} do
      counter = :counters.new(1, [:atomics])

      {:ok, pid, _memory_store, _routing_feedback_store} =
        start_isolated_ingest(tmp_dir, counter, %{})

      for i <- 1..3 do
        {_run_id, record, summary} = make_ingest_args()
        MemoryIngest.ingest(pid, "run_#{i}", record, summary)
      end

      :sys.get_state(pid)

      # 3 ingests → exactly 3 config loads (1 per ingest)
      assert :counters.get(counter, 1) == 3

      stop_if_alive(pid)
    end
  end

  defp start_isolated_ingest(tmp_dir, counter, features) do
    memory_path = Path.join(tmp_dir, "memory_#{System.unique_integer([:positive])}")
    routing_path = Path.join(tmp_dir, "routing_#{System.unique_integer([:positive])}")
    memory_name = :"memory_store_#{System.unique_integer([:positive])}"
    routing_name = :"routing_feedback_store_#{System.unique_integer([:positive])}"

    {:ok, memory_store} = LemonCore.MemoryStore.start_link(path: memory_path, name: memory_name)

    {:ok, routing_feedback_store} =
      LemonCore.RoutingFeedbackStore.start_link(
        path: routing_path,
        min_sample_size: 1,
        name: routing_name
      )

    {:ok, pid} =
      GenServer.start_link(MemoryIngest,
        config_loader: fn ->
          :counters.add(counter, 1, 1)
          %{features: build_feature_flags(features)}
        end,
        memory_store: memory_store,
        routing_feedback_store: routing_feedback_store
      )

    on_exit(fn ->
      stop_if_alive(pid)
      stop_if_alive(memory_store)
      stop_if_alive(routing_feedback_store)
    end)

    {:ok, pid, memory_store, routing_feedback_store}
  end

  defp build_feature_flags(features) do
    %LemonCore.Config.Features{
      session_search: rollout_state(Map.get(features, :session_search, false)),
      routing_feedback: rollout_state(Map.get(features, :routing_feedback, false))
    }
  end

  defp rollout_state(true), do: :"default-on"
  defp rollout_state(false), do: :off

  defp stop_if_alive(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  end
end
