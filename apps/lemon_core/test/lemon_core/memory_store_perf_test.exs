defmodule LemonCore.MemoryStorePerfTest do
  @moduledoc """
  Performance and correctness guardrails for M5 memory store.

  These tests verify that FTS queries and basic store operations stay within
  acceptable latency bounds on a realistic fixture dataset.

  Tagged `:memory_perf` so CI can run them explicitly:

      mix test --only memory_perf

  They are excluded by default to keep the standard test suite fast.
  """

  use ExUnit.Case, async: false

  alias LemonCore.MemoryDocument
  alias LemonCore.MemoryStore

  @moduletag :memory_perf
  @fixture_count 200

  # Latency budgets
  @search_budget_ms 200
  @put_budget_ms 50

  setup do
    tmp = System.tmp_dir!()
    dir = Path.join(tmp, "memory_perf_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    name = :"memory_perf_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      start_supervised(
        {MemoryStore,
         [
           name: name,
           path: dir,
           retention_ms: 365 * 24 * 3600_000,
           max_per_scope: 10_000
         ]}
      )

    on_exit(fn -> File.rm_rf(dir) end)
    %{store_pid: pid}
  end

  test "insert #{@fixture_count} documents within budget", %{store_pid: pid} do
    session = "agent:perf_insert:main"
    docs = Enum.map(1..@fixture_count, fn i -> make_doc(session, i) end)

    t0 = System.monotonic_time(:millisecond)

    Enum.each(docs, fn doc ->
      MemoryStore.put(pid, doc)
    end)

    # Wait for all async casts to be processed
    assert eventually(fn ->
      MemoryStore.get_by_session(pid, session, limit: @fixture_count) |> length() >= @fixture_count
    end, 100)

    elapsed = System.monotonic_time(:millisecond) - t0
    avg = div(elapsed, @fixture_count)
    assert avg <= @put_budget_ms,
           "Average put latency #{avg}ms exceeds #{@put_budget_ms}ms budget"
  end

  test "FTS search over #{@fixture_count} docs completes under #{@search_budget_ms}ms", %{store_pid: pid} do
    session = "agent:perf_search:main"
    docs = Enum.map(1..@fixture_count, fn i -> make_doc(session, i) end)

    Enum.each(docs, fn doc ->
      MemoryStore.put(pid, doc)
    end)

    assert eventually(fn ->
      MemoryStore.get_by_session(pid, session, limit: @fixture_count) |> length() >= @fixture_count
    end, 100)

    # Warm the search path
    MemoryStore.search(pid, "deploy release", scope: :session, scope_key: session, limit: 10)

    # Measure actual search
    t0 = System.monotonic_time(:millisecond)
    results = MemoryStore.search(pid, "deploy release", scope: :session, scope_key: session, limit: 10)
    elapsed = System.monotonic_time(:millisecond) - t0

    assert elapsed <= @search_budget_ms,
           "FTS search took #{elapsed}ms, exceeds #{@search_budget_ms}ms budget"

    assert length(results) > 0, "FTS search should return at least one result"
  end

  test "FTS search correctness: finds documents by keyword", %{store_pid: pid} do
    session = "agent:perf_correctness:main"

    unique_word = "xk7q9zfj"

    needle = %MemoryDocument{
      doc_id: "mem_needle",
      run_id: "run_needle",
      session_key: session,
      agent_id: "correctness_agent",
      workspace_key: nil,
      scope: :session,
      started_at_ms: System.system_time(:millisecond) - 100,
      ingested_at_ms: System.system_time(:millisecond),
      prompt_summary: "How to fix the #{unique_word} problem?",
      answer_summary: "Use the standard approach.",
      tools_used: ["bash"],
      provider: "anthropic",
      model: "claude-sonnet-4-6",
      outcome: :unknown,
      meta: %{}
    }

    # Insert noise documents without the unique word
    Enum.each(1..50, fn i -> MemoryStore.put(pid, make_doc(session, i)) end)
    MemoryStore.put(pid, needle)

    assert eventually(fn ->
      MemoryStore.get_by_session(pid, session, limit: 100) |> length() >= 51
    end, 100)

    results = MemoryStore.search(pid, unique_word, scope: :session, scope_key: session, limit: 10)
    assert Enum.any?(results, &(&1.doc_id == "mem_needle")),
           "Expected needle document to appear in FTS results for #{inspect(unique_word)}"
  end

  test "prune enforces max_per_scope", %{store_pid: _pid} do
    session = "agent:prune_max:main"

    # Start an isolated store with max_per_scope = 5
    tmp = System.tmp_dir!()
    dir2 = Path.join(tmp, "memory_perf_prune_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir2)

    name2 = :"memory_perf_prune_#{System.unique_integer([:positive])}"

    {:ok, pid2} =
      MemoryStore.start_link([
        name: name2,
        path: dir2,
        retention_ms: 365 * 24 * 3600_000,
        max_per_scope: 5
      ])

    on_exit(fn ->
      if Process.alive?(pid2), do: GenServer.stop(pid2)
      File.rm_rf(dir2)
    end)

    Enum.each(1..10, fn i -> MemoryStore.put(pid2, make_doc(session, i)) end)

    assert eventually(fn ->
      MemoryStore.get_by_session(pid2, session, limit: 20) |> length() >= 10
    end, 100)

    {:ok, %{pruned: _}} = MemoryStore.prune(pid2)

    results = MemoryStore.get_by_session(pid2, session, limit: 20)
    assert length(results) <= 5,
           "Expected at most 5 documents after prune, got #{length(results)}"
  end

  # ── Helpers ────────────────────────────────────────────────────────────────────

  defp make_doc(session, i) do
    now = System.system_time(:millisecond)

    %MemoryDocument{
      doc_id: "mem_perf_#{i}_#{System.unique_integer([:positive])}",
      run_id: "run_perf_#{i}",
      session_key: session,
      agent_id: "perf_agent",
      workspace_key: nil,
      scope: :session,
      started_at_ms: now - 5_000,
      ingested_at_ms: now + i,
      prompt_summary: "How do I deploy release #{i} to production?",
      answer_summary: "Run mix release and ship the tarball for build #{i}.",
      tools_used: ["bash"],
      provider: "anthropic",
      model: "claude-sonnet-4-6",
      outcome: :unknown,
      meta: %{}
    }
  end

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
