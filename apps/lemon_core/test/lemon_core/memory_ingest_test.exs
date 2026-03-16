defmodule LemonCore.MemoryIngestTest do
  @moduledoc """
  Tests for LemonCore.MemoryIngest — focusing on J6: config must be loaded
  exactly once per ingest call, not once per feature-flag check.
  """

  use ExUnit.Case, async: false

  alias LemonCore.MemoryIngest

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
    test "handle_cast loads config exactly once regardless of how many feature flags are checked" do
      # Use a :counters atomic to track config loads (safe from concurrent access)
      counter = :counters.new(1, [:atomics])

      # Start an isolated MemoryIngest with a custom config loader
      {:ok, pid} =
        GenServer.start_link(MemoryIngest, [
          config_loader: fn ->
            :counters.add(counter, 1, 1)
            # Return a config with both feature flags off to avoid side-effects
            %{features: %{}}
          end
        ])

      {run_id, record, summary} = make_ingest_args()

      # Dispatch one ingest (as a direct cast to bypass the named-process guard)
      GenServer.cast(pid, {:ingest, run_id, record, summary})

      # :sys.get_state/1 is a synchronous OTP call that flushes the cast queue
      :sys.get_state(pid)

      loads = :counters.get(counter, 1)

      assert loads == 1,
             "expected config to be loaded exactly once per ingest, got #{loads} loads"

      GenServer.stop(pid)
    end

    test "config is loaded once even when both session_search and routing_feedback are enabled" do
      counter = :counters.new(1, [:atomics])

      {:ok, pid} =
        GenServer.start_link(MemoryIngest, [
          config_loader: fn ->
            :counters.add(counter, 1, 1)
            # Both flags enabled
            %{
              features: %{
                session_search: true,
                routing_feedback: true
              }
            }
          end
        ])

      {run_id, record, summary} = make_ingest_args()
      GenServer.cast(pid, {:ingest, run_id, record, summary})
      :sys.get_state(pid)

      assert :counters.get(counter, 1) == 1

      GenServer.stop(pid)
    end

    test "config is loaded once per ingest across multiple ingest calls" do
      counter = :counters.new(1, [:atomics])

      {:ok, pid} =
        GenServer.start_link(MemoryIngest, [
          config_loader: fn ->
            :counters.add(counter, 1, 1)
            %{features: %{}}
          end
        ])

      for i <- 1..3 do
        {run_id, record, summary} = make_ingest_args()
        GenServer.cast(pid, {:ingest, "run_#{i}", record, summary})
      end

      :sys.get_state(pid)

      # 3 ingests → exactly 3 config loads (1 per ingest)
      assert :counters.get(counter, 1) == 3

      GenServer.stop(pid)
    end
  end
end
