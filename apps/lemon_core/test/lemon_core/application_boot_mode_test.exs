defmodule LemonCore.ApplicationBootModeTest do
  @moduledoc "Client boot mode for one-shot commands (#667)."
  use ExUnit.Case, async: false

  alias LemonCore.Store

  defp ids(children) do
    Enum.map(children, fn
      {module, _opts} when is_atom(module) -> module
      %{id: id} -> id
      module when is_atom(module) -> module
    end)
  end

  defp opts(children, module) do
    Enum.find_value(children, fn
      {^module, opts} -> opts
      ^module -> []
      _ -> nil
    end)
  end

  test "the client child list excludes ownership, recovery, sweeps, reloaders and run history" do
    for mode <- [:client, :read_only_client] do
      children = LemonCore.Application.children(mode)
      ids = ids(children)

      for absent <- [
            LemonCore.RunHistoryStore,
            LemonCore.ConfigReloader,
            LemonCore.ConfigReloader.Watcher,
            LemonCore.Drain
          ],
          do: refute(absent in ids, "#{inspect(mode)} starts #{inspect(absent)}")

      assert opts(children, LemonCore.ExecApprovalExpiry) ==
               [recover: false, approvals: LemonCore.ExecApprovals]
      assert Keyword.get(opts(children, Store), :sweep) == false
    end

    assert Keyword.get(opts(LemonCore.Application.children(:read_only_client), Store), :read_only)
    refute Keyword.get(opts(LemonCore.Application.children(:client), Store), :read_only)
    assert Keyword.get(opts(LemonCore.Application.children(:client), Store), :defer_to_runtime)
    # Only a writable client holds the ownership locks (and never recovers).
    assert opts(LemonCore.Application.children(:client), LemonCore.RuntimeOwner) == [client: true]
    refute LemonCore.RuntimeOwner in ids(LemonCore.Application.children(:read_only_client))
  end

  test "the runtime child list keeps ownership, recovery, sweeps and reloaders" do
    children = LemonCore.Application.children(:runtime)
    ids = ids(children)

    for present <- [
          LemonCore.RuntimeOwner,
          LemonCore.ConfigReloader,
          LemonCore.ConfigReloader.Watcher,
          LemonCore.Drain
        ],
        do: assert(present in ids)

    assert opts(children, LemonCore.ExecApprovalExpiry) ==
             [recover: true, approvals: LemonCore.ExecApprovals]
    assert opts(children, Store) == []
  end

  test "boot_mode/0 defaults to the runtime" do
    previous = Application.get_env(:lemon_core, :boot_mode)
    on_exit(fn -> restore(:boot_mode, previous) end)

    Application.delete_env(:lemon_core, :boot_mode)
    assert LemonCore.Application.boot_mode() == :runtime
    Application.put_env(:lemon_core, :boot_mode, :read_only_client)
    assert LemonCore.Application.boot_mode() == :read_only_client
    Application.put_env(:lemon_core, :boot_mode, :bogus)
    assert LemonCore.Application.boot_mode() == :runtime
  end

  test "a read-only store refuses every mutation and still serves reads" do
    name = :boot_mode_read_only_store
    store = start_supervised!({Store, name: name, read_only: true, sweep: false}, id: :reader)

    for result <- [
          Store.put(name, :probe, :key, :value),
          Store.put_new(name, :probe, :other, :value),
          Store.compare_and_swap(name, :probe, :key, nil, :value),
          Store.delete(name, :probe, :key),
          Store.compare_and_delete(name, :probe, :key, :value),
          Store.finalize_run(name, "run-read-only", %{})
        ],
        do: assert(result == {:error, :read_only})

    Store.append_run_event(name, "run-read-only", %{type: :ignored})
    assert :ok = Store.ping(name)
    assert {:ok, nil} = Store.fetch(name, :probe, :key)
    assert {:ok, []} = Store.fetch_all(name, :probe)
    assert Process.alive?(store)
  end

  # Both start orders over one database; a RuntimeOwner started without its
  # registered name plays the daemon beside the test VM's own.
  @tag :tmp_dir
  test "a runtime started first keeps a writable client store from writing", %{tmp_dir: tmp_dir} do
    {database, client} = client_store_opts(tmp_dir)
    {:ok, runtime} = GenServer.start(LemonCore.RuntimeOwner, database: database)
    on_exit(fn -> stop_quietly(runtime) end)
    assert GenServer.call(runtime, :owner?)

    start_supervised!({Store, [name: :boot_mode_owned_client] ++ client}, id: :owned)
    assert {:error, :runtime_owned} = Store.write_access(:boot_mode_owned_client)

    for result <- [
          Store.put(:boot_mode_owned_client, :probe, :key, :after),
          Store.delete(:boot_mode_owned_client, :probe, :key),
          Store.finalize_run(:boot_mode_owned_client, "run-owned", %{})
        ],
        do: assert(result == {:error, :runtime_owned})

    assert {:ok, nil} = Store.fetch(:boot_mode_owned_client, :probe, :key)
    assert GenServer.call(runtime, :owner?)
  end

  @tag :tmp_dir
  test "a runtime started after a writable client refuses instead of writing", %{
    tmp_dir: tmp_dir
  } do
    {database, client} = client_store_opts(tmp_dir)
    start_supervised!({Store, [name: :boot_mode_leased_client] ++ client}, id: :leased)
    assert {:error, :runtime_owned} = Store.write_access(:boot_mode_leased_client)

    # The client's ownership process holds the locks, then lets its store write.
    {:ok, client_owner} =
      GenServer.start(LemonCore.RuntimeOwner,
        client: true,
        database: database,
        store: :boot_mode_leased_client
      )

    assert :ok = Store.write_access(:boot_mode_leased_client)
    assert :ok = Store.put(:boot_mode_leased_client, :probe, :key, :before)

    # A runtime booting meanwhile waits its lock deadline, then refuses.
    Process.flag(:trap_exit, true)

    assert {:error, :store_held_by_client} =
             GenServer.start(LemonCore.RuntimeOwner, database: database)

    assert :ok = Store.put(:boot_mode_leased_client, :probe, :key, :still_only_writer)

    # The client ends: its store stops writing and the runtime can own the database.
    GenServer.stop(client_owner)
    assert {:error, :runtime_owned} = Store.write_access(:boot_mode_leased_client)
    {:ok, runtime} = GenServer.start(LemonCore.RuntimeOwner, database: database)
    on_exit(fn -> stop_quietly(runtime) end)
    assert GenServer.call(runtime, :owner?)
    assert {:ok, :still_only_writer} = Store.fetch(:boot_mode_leased_client, :probe, :key)
  end

  defp client_store_opts(tmp_dir) do
    database = Path.join(tmp_dir, "store.sqlite3")

    {database,
     [
       sweep: false,
       defer_to_runtime: true,
       backend: LemonCore.Store.SqliteBackend,
       backend_opts: [path: database]
     ]}
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  test "read-only and in-memory stores report their write access" do
    start_supervised!({Store, name: :boot_mode_access_ro, read_only: true}, id: :ro)
    start_supervised!({Store, name: :boot_mode_access_mem, defer_to_runtime: true}, id: :mem)

    assert {:error, :read_only} = Store.write_access(:boot_mode_access_ro)
    assert :ok = Store.write_access(:boot_mode_access_mem)
  end

  test "LemonCore.CLI.start/2 keeps the mode of a running :lemon_core" do
    previous = Application.get_env(:lemon_core, :boot_mode)
    on_exit(fn -> restore(:boot_mode, previous) end)

    assert :ok = LemonCore.CLI.start(:lemon_core, store: :read_only)
    assert Application.get_env(:lemon_core, :boot_mode) == previous
  end

  defp restore(key, nil), do: Application.delete_env(:lemon_core, key)
  defp restore(key, value), do: Application.put_env(:lemon_core, key, value)
end
