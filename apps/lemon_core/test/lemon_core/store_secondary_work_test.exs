defmodule LemonCore.StoreSecondaryWorkTest do
  use ExUnit.Case, async: false

  alias LemonCore.Store
  alias LemonCore.Store.EtsBackend

  defmodule ClosingBackend do
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}
    def list(state, _table), do: {:ok, [], state}
    def close(%{owner: owner}), do: send(owner, :backend_closed)
  end

  test "normal Store shutdown closes the backend" do
    pid =
      start_supervised!(
        {Store,
         name: :secondary_close_store,
         backend: ClosingBackend,
         backend_opts: [owner: self()],
         cached_tables: []}
      )

    stop_supervised!(Store)
    refute Process.alive?(pid)
    assert_receive :backend_closed
  end

  test "a hook may call Store and block without blocking the Store owner" do
    parent = self()

    hook = fn %{store: store} ->
      send(parent, {:hook_ready, self(), Store.ping(store)})

      receive do
        :release -> :ok
      end
    end

    store = :secondary_hook_store
    start_supervised!({Store, name: store, backend: EtsBackend, finalize_run_hooks: [hook]})
    caller = Task.async(fn -> Store.finalize_run(store, "run", %{}) end)
    assert_receive {:hook_ready, hook_pid, :ok}
    assert hook_pid != Process.whereis(store)
    assert :ok = Store.put(store, :notes, :key, :value)
    assert :value = Store.get(store, :notes, :key)
    send(hook_pid, :release)
    assert :ok = Task.await(caller)
  end

  test "hook budget kills stuck work but preserves the finalized record" do
    previous = Application.get_env(:lemon_core, :store_hook_budget_ms)
    Application.put_env(:lemon_core, :store_hook_budget_ms, 0)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:lemon_core, :store_hook_budget_ms),
        else: Application.put_env(:lemon_core, :store_hook_budget_ms, previous)
    end)

    store = :secondary_budget_store

    hook = fn _ ->
      receive do
        :never -> :ok
      end
    end

    start_supervised!({Store, name: store, backend: EtsBackend, finalize_run_hooks: [hook]})
    assert :ok = Store.finalize_run(store, "run", %{result: :done})
    assert %{summary: %{result: :done}} = Store.get_run(store, "run")
    assert :ok = Store.ping(store)
  end

  test "sweep preserves live mirrored rows and deletes expired ones" do
    store = :secondary_sweep_store
    pid = start_supervised!({Store, name: store, backend: EtsBackend})
    now = System.system_time(:millisecond)
    assert :ok = Store.put(store, :chat, :old, %{expires_at: now - 1})
    assert :ok = Store.put(store, :chat, :live, %{expires_at: now + 60_000})
    send(pid, :sweep_expired)
    assert :ok = Store.ping(store)
    assert nil == Store.get(store, :chat, :old)
    assert %{expires_at: _} = Store.get(store, :chat, :live)
  end
end
