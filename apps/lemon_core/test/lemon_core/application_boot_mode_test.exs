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
            LemonCore.RuntimeOwner,
            LemonCore.RunHistoryStore,
            LemonCore.ConfigReloader,
            LemonCore.ConfigReloader.Watcher,
            LemonCore.Drain
          ],
          do: refute(absent in ids, "#{inspect(mode)} starts #{inspect(absent)}")

      assert opts(children, LemonCore.ExecApprovalExpiry) == [recover: false]
      assert Keyword.get(opts(children, Store), :sweep) == false
    end

    assert Keyword.get(opts(LemonCore.Application.children(:read_only_client), Store), :read_only)
    refute Keyword.get(opts(LemonCore.Application.children(:client), Store), :read_only)
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

    assert opts(children, LemonCore.ExecApprovalExpiry) == [recover: true]
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

  test "LemonCore.CLI.start/2 keeps the mode of a running :lemon_core" do
    previous = Application.get_env(:lemon_core, :boot_mode)
    on_exit(fn -> restore(:boot_mode, previous) end)

    assert :ok = LemonCore.CLI.start(:lemon_core, store: :read_only)
    assert Application.get_env(:lemon_core, :boot_mode) == previous
  end

  defp restore(key, nil), do: Application.delete_env(:lemon_core, key)
  defp restore(key, value), do: Application.put_env(:lemon_core, key, value)
end
