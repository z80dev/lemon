defmodule LemonMemory.IngestTest do
  @moduledoc """
  Tests for LemonMemory.Ingest — feature gating, config caching (the hot path
  must not run a full TOML config load on every finalized run), and the
  disabled-features short-circuit that skips `Document.from_run/3` entirely.
  """

  use ExUnit.Case, async: false

  alias LemonCore.Bus
  alias LemonCore.Event
  alias LemonMemory.Ingest

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

  describe "config caching" do
    test "config is loaded once and cached across ingests within the TTL", %{tmp_dir: tmp_dir} do
      counter = :counters.new(1, [:atomics])

      {:ok, pid, _memory_store} = start_isolated_ingest(tmp_dir, counter, %{})

      for i <- 1..3 do
        {_run_id, record, summary} = make_ingest_args()
        Ingest.ingest(pid, "run_#{i}", record, summary)
      end

      :sys.get_state(pid)

      # 3 ingests within the TTL → exactly 1 config load
      assert :counters.get(counter, 1) == 1

      stop_if_alive(pid)
    end

    test "config is reloaded once the TTL has elapsed", %{tmp_dir: tmp_dir} do
      counter = :counters.new(1, [:atomics])

      # TTL of 0 means every ingest sees an expired cache and reloads.
      {:ok, pid, _memory_store} = start_isolated_ingest(tmp_dir, counter, %{}, config_ttl_ms: 0)

      for i <- 1..3 do
        {_run_id, record, summary} = make_ingest_args()
        Ingest.ingest(pid, "run_#{i}", record, summary)
      end

      :sys.get_state(pid)

      assert :counters.get(counter, 1) == 3

      stop_if_alive(pid)
    end
  end

  describe "feature gating" do
    test "session_search off: nothing is written and no routing feedback is broadcast", %{
      tmp_dir: tmp_dir
    } do
      counter = :counters.new(1, [:atomics])
      Bus.subscribe("routing_feedback")

      {:ok, pid, memory_store} = start_isolated_ingest(tmp_dir, counter, %{})

      {run_id, record, summary} = make_ingest_args()

      Ingest.ingest(pid, run_id, record, summary)
      :sys.get_state(pid)

      assert [] =
               LemonMemory.Store.get_by_session(memory_store, summary.session_key, limit: 10)

      refute_receive %Event{type: :routing_feedback}, 50

      stop_if_alive(pid)
    end

    test "session_search on: the finalized run is written to the store", %{tmp_dir: tmp_dir} do
      counter = :counters.new(1, [:atomics])

      {:ok, pid, memory_store} = start_isolated_ingest(tmp_dir, counter, %{session_search: true})

      {run_id, record, summary} = make_ingest_args()

      Ingest.ingest(pid, run_id, record, summary)
      :sys.get_state(pid)

      assert [doc] =
               LemonMemory.Store.get_by_session(memory_store, summary.session_key, limit: 10)

      assert doc.run_id == run_id

      stop_if_alive(pid)
    end

    test "routing_feedback on: feedback is broadcast and config still loads once", %{
      tmp_dir: tmp_dir
    } do
      counter = :counters.new(1, [:atomics])
      Bus.subscribe("routing_feedback")

      {:ok, pid, _memory_store} =
        start_isolated_ingest(tmp_dir, counter, %{session_search: true, routing_feedback: true})

      {run_id, record, summary} = make_ingest_args()
      Ingest.ingest(pid, run_id, record, summary)
      :sys.get_state(pid)

      assert :counters.get(counter, 1) == 1
      assert_receive %Event{type: :routing_feedback, payload: payload}
      assert payload.fingerprint_key =~ "code|-|-|anthropic|claude-sonnet-4-6"
      assert payload.outcome == :success
      assert is_nil(payload.duration_ms) or is_integer(payload.duration_ms)

      stop_if_alive(pid)
    end
  end

  describe "disabled-features short-circuit" do
    test "skips Document.from_run entirely when both features are disabled", %{tmp_dir: tmp_dir} do
      counter = :counters.new(1, [:atomics])
      attach_failure_handler()

      {:ok, pid, _memory_store} = start_isolated_ingest(tmp_dir, counter, %{})

      # This summary would raise inside Document.from_run/3 (not a map). With
      # both features off, ingest must return before ever building the doc,
      # so no failure telemetry fires.
      Ingest.ingest(pid, "run_short_circuit", %{}, :not_a_map)
      :sys.get_state(pid)

      refute_receive {:ingest_failure, _}, 50

      # Feature flags were still resolved (one cached config load).
      assert :counters.get(counter, 1) == 1
      assert Process.alive?(pid)

      stop_if_alive(pid)
    end

    test "a malformed summary still hits the isolated failure path when a feature is enabled",
         %{tmp_dir: tmp_dir} do
      counter = :counters.new(1, [:atomics])
      attach_failure_handler()

      {:ok, pid, _memory_store} = start_isolated_ingest(tmp_dir, counter, %{session_search: true})

      Ingest.ingest(pid, "run_bad_summary", %{}, :not_a_map)
      :sys.get_state(pid)

      assert_receive {:ingest_failure, meta}
      assert meta.run_id == "run_bad_summary"
      assert Process.alive?(pid)

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

      Ingest.ingest(pid, run_id, record, summary)
      :sys.get_state(pid)

      assert [] =
               LemonMemory.Store.get_by_session(memory_store, summary.session_key, limit: 10)

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

      Ingest.ingest(pid, run_id, record, summary)
      :sys.get_state(pid)

      assert [] =
               LemonMemory.Store.get_by_session(memory_store, summary.session_key, limit: 10)

      stop_if_alive(pid)
    end
  end

  defp start_isolated_ingest(tmp_dir, counter, features, extra_opts \\ []) do
    memory_path = Path.join(tmp_dir, "memory_#{System.unique_integer([:positive])}")
    memory_name = :"memory_store_#{System.unique_integer([:positive])}"

    {:ok, memory_store} = LemonMemory.Store.start_link(path: memory_path, name: memory_name)

    {:ok, pid} =
      GenServer.start_link(
        Ingest,
        [
          config_loader: fn ->
            :counters.add(counter, 1, 1)
            %{features: build_feature_flags(features)}
          end,
          memory_store: memory_store
        ] ++ extra_opts
      )

    on_exit(fn ->
      stop_if_alive(pid)
      stop_if_alive(memory_store)
    end)

    {:ok, pid, memory_store}
  end

  defp attach_failure_handler do
    handler_id = "ingest-test-failure-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:lemon, :memory, :ingest, :failure],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:ingest_failure, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
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
