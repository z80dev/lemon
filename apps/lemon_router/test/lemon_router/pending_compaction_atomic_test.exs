defmodule LemonRouter.PendingCompactionAtomicTest do
  use ExUnit.Case, async: false

  alias LemonRouter.{PendingCompaction, PendingCompactionStore}

  defmodule MarkerBackend do
    def get(%{key: key, marker: marker, replace: replacement} = state, :pending_compaction, key)
        when is_map(replacement) do
      # Return the inspected A snapshot while committing B before the next call.
      {:ok, marker, %{state | marker: replacement, replace: nil}}
    end

    def get(%{key: key} = state, :pending_compaction, key),
      do: {:ok, state.marker, state}

    def get(state, _table, _key), do: {:ok, nil, state}

    def delete(%{fail: true}, :pending_compaction, _key), do: {:error, :write_failed}
    def delete(state, :pending_compaction, _key), do: {:ok, %{state | marker: nil}}
    def list(state, _table), do: {:ok, [], state}
    def sync(state), do: {:ok, state}
  end

  defp install_marker(marker, opts \\ []) do
    key = "atomic-compaction-#{System.unique_integer([:positive])}"
    original = :sys.get_state(LemonCore.Store)

    :sys.replace_state(LemonCore.Store, fn state ->
      %{state | backend: MarkerBackend, backend_state: %{
        key: key, marker: marker, replace: opts[:replace], fail: opts[:fail] || false
      }}
    end)

    on_exit(fn -> :sys.replace_state(LemonCore.Store, fn _ -> original end) end)
    key
  end

  test "consume preserves a replacement and treats mismatch as benign" do
    a = %{generation: 1}
    b = %{generation: 2}
    key = install_marker(b)
    assert {:error, :mismatch} = PendingCompactionStore.compare_and_delete(key, a)
    assert :ok = PendingCompaction.consume(key, a)
    assert PendingCompactionStore.get(key) == b
    assert :ok = PendingCompaction.consume(key, b)
    assert PendingCompactionStore.get(key) == nil
  end

  for kind <- [:stale, :empty] do
    test "#{kind} cleanup preserves a marker installed after inspection" do
      timestamp = if unquote(kind) == :stale, do: 0, else: System.system_time(:millisecond)
      a = %{generation: 1, set_at_ms: timestamp}
      b = %{generation: 2, set_at_ms: System.system_time(:millisecond)}
      key = install_marker(a, replace: b)
      assert {"continue", nil} = PendingCompaction.prepare("continue", key, :channel)
      assert PendingCompactionStore.get(key) == b
    end

    test "#{kind} cleanup propagates storage failure" do
      timestamp = if unquote(kind) == :stale, do: 0, else: System.system_time(:millisecond)
      marker = %{set_at_ms: timestamp}
      key = install_marker(marker, fail: true)
      assert {:error, :write_failed} = PendingCompaction.prepare("continue", key, :channel)
      assert PendingCompactionStore.get(key) == marker
    end
  end

  test "consume returns the actual storage error without consuming the marker" do
    marker = %{generation: 1}
    key = install_marker(marker, fail: true)
    assert {:error, :write_failed} = PendingCompaction.consume(key, marker)
    assert PendingCompactionStore.get(key) == marker
  end
end
