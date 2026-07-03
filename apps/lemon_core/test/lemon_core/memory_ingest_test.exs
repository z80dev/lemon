defmodule LemonCore.MemoryIngestTest do
  @moduledoc """
  Tests for LemonCore.MemoryIngest — focusing on J6: config must be loaded
  exactly once per ingest call, not once per feature-flag check.
  """

  use ExUnit.Case, async: false

  alias LemonCore.Bus
  alias LemonCore.Event
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
      Bus.subscribe("routing_feedback")

      {:ok, pid, _memory_store} = start_isolated_ingest(tmp_dir, counter, %{})

      {run_id, record, summary} = make_ingest_args()

      MemoryIngest.ingest(pid, run_id, record, summary)
      :sys.get_state(pid)

      loads = :counters.get(counter, 1)

      assert loads == 1,
             "expected config to be loaded exactly once per ingest, got #{loads} loads"

      refute_receive %Event{type: :routing_feedback}, 50

      stop_if_alive(pid)
    end

    test "config is loaded once even when both session_search and routing_feedback are enabled",
         %{tmp_dir: tmp_dir} do
      counter = :counters.new(1, [:atomics])
      Bus.subscribe("routing_feedback")

      {:ok, pid, _memory_store} =
        start_isolated_ingest(tmp_dir, counter, %{session_search: true, routing_feedback: true})

      {run_id, record, summary} = make_ingest_args()
      MemoryIngest.ingest(pid, run_id, record, summary)
      :sys.get_state(pid)

      assert :counters.get(counter, 1) == 1
      assert_receive %Event{type: :routing_feedback, payload: payload}
      assert payload.fingerprint_key =~ "code|-|-|anthropic|claude-sonnet-4-6"
      assert payload.outcome == :success
      assert is_nil(payload.duration_ms) or is_integer(payload.duration_ms)

      stop_if_alive(pid)
    end

    test "config is loaded once per ingest across multiple ingest calls", %{tmp_dir: tmp_dir} do
      counter = :counters.new(1, [:atomics])

      {:ok, pid, _memory_store} = start_isolated_ingest(tmp_dir, counter, %{})

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

  describe "secret filtering" do
    test "does not store runs whose prompt summary contains secret-looking content", %{
      tmp_dir: tmp_dir
    } do
      counter = :counters.new(1, [:atomics])

      {:ok, pid, memory_store} = start_isolated_ingest(tmp_dir, counter, %{session_search: true})

      {run_id, record, summary} = make_ingest_args()
      summary = %{summary | prompt: "implement deployment password=hunter2"}

      MemoryIngest.ingest(pid, run_id, record, summary)
      :sys.get_state(pid)

      assert [] =
               LemonCore.MemoryStore.get_by_session(memory_store, summary.session_key, limit: 10)

      assert :counters.get(counter, 1) == 0

      stop_if_alive(pid)
    end

    test "does not store runs whose answer summary contains secret-looking content", %{
      tmp_dir: tmp_dir
    } do
      counter = :counters.new(1, [:atomics])

      {:ok, pid, memory_store} = start_isolated_ingest(tmp_dir, counter, %{session_search: true})

      {run_id, record, summary} = make_ingest_args()

      summary = %{
        summary
        | completed: %{ok: true, answer: "done sk-proj-abcdefghijklmnopqrstuvwxyz1234567890"}
      }

      MemoryIngest.ingest(pid, run_id, record, summary)
      :sys.get_state(pid)

      assert [] =
               LemonCore.MemoryStore.get_by_session(memory_store, summary.session_key, limit: 10)

      assert :counters.get(counter, 1) == 0

      stop_if_alive(pid)
    end
  end

  defp start_isolated_ingest(tmp_dir, counter, features) do
    memory_path = Path.join(tmp_dir, "memory_#{System.unique_integer([:positive])}")
    memory_name = :"memory_store_#{System.unique_integer([:positive])}"

    {:ok, memory_store} = LemonCore.MemoryStore.start_link(path: memory_path, name: memory_name)

    {:ok, pid} =
      GenServer.start_link(MemoryIngest,
        config_loader: fn ->
          :counters.add(counter, 1, 1)
          %{features: build_feature_flags(features)}
        end,
        memory_store: memory_store
      )

    on_exit(fn ->
      stop_if_alive(pid)
      stop_if_alive(memory_store)
    end)

    {:ok, pid, memory_store}
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
