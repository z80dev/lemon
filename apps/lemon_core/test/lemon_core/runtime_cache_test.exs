defmodule LemonCore.RuntimeCacheTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonCore.{Bus, ExecApprovalExpiry, RuntimeCache}
  alias LemonCore.Store.Hooks

  setup do
    key = {__MODULE__, make_ref()}
    on_exit(fn -> :ets.delete(RuntimeCache, key) end)
    %{key: key}
  end

  test "runtime publications outlive their caller and reads bypass the owner", %{key: key} do
    {caller, monitor} = spawn_monitor(fn -> RuntimeCache.put(key, :retained) end)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    owner = Process.whereis(RuntimeCache)
    assert :ets.info(RuntimeCache, :owner) == owner

    assert {RuntimeCache, owner, :worker, [RuntimeCache]} in Supervisor.which_children(
             LemonCore.Supervisor
           )

    :ok = :sys.suspend(owner)

    try do
      assert RuntimeCache.get(key) == :retained
      assert RuntimeCache.get({key, :missing}, :absent) == :absent
      assert :ok = Hooks.publish(:runtime_cache_publication, :cached_tables, [:hot_index])
      assert Hooks.published(:runtime_cache_publication, :cached_tables) == [:hot_index]
    after
      :sys.resume(owner)
      :ets.delete(RuntimeCache, {Hooks, :runtime_cache_publication, :cached_tables, :published})
    end
  end

  test "a warning is claimed exactly once across concurrent callers", %{key: key} do
    parent = self()

    tasks =
      for _ <- 1..32 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :claim -> RuntimeCache.warn_once?(key)
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _pid})
    for task <- tasks, do: send(task.pid, :claim)
    assert Enum.count(Task.await_many(tasks), & &1) == 1
    assert RuntimeCache.get(key) == true
  end

  test "missing hook warnings use the supervised once flag" do
    missing = LemonCore.RuntimeCacheTest.MissingHook
    key = {Hooks, :missing_hook_module, missing}
    :ets.delete(RuntimeCache, key)
    on_exit(fn -> :ets.delete(RuntimeCache, key) end)

    log =
      capture_log(fn ->
        for _ <- 1..2, do: Hooks.invoke([{missing, :on_run}], %{})
      end)

    assert length(Regex.scan(~r/Logged once per module/, log)) == 1
    assert RuntimeCache.get(key) == true
  end

  test "automatic bus detection does not lazily publish" do
    key = {Bus, :backend}
    original = :persistent_term.get(key)
    backend_config = Application.fetch_env(:lemon_core, :bus_backend)
    :persistent_term.erase(key)
    Application.put_env(:lemon_core, :bus_backend, :auto)

    try do
      assert Bus.backend() in [:pubsub, :registry]
      assert :persistent_term.get(key, :missing) == :missing
    after
      :persistent_term.put(key, original)

      case backend_config do
        {:ok, value} -> Application.put_env(:lemon_core, :bus_backend, value)
        :error -> Application.delete_env(:lemon_core, :bus_backend)
      end
    end
  end

  test "approval runtime identity is initialized only by explicit boot publication" do
    key = {ExecApprovalExpiry, :runtime_id}
    original = ExecApprovalExpiry.runtime_id()
    :persistent_term.erase(key)

    try do
      assert_raise ArgumentError, fn -> ExecApprovalExpiry.runtime_id() end
      assert :persistent_term.get(key, :missing) == :missing
      initialized = ExecApprovalExpiry.init_runtime_id()
      assert is_binary(initialized)
      assert ExecApprovalExpiry.runtime_id() == initialized
      assert ExecApprovalExpiry.init_runtime_id() == initialized
    after
      :persistent_term.put(key, original)
    end
  end
end
