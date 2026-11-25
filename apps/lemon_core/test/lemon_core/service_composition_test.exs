defmodule LemonCore.ServiceCompositionTest do
  @moduledoc "Service groups and boot capability checks (#92)."
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonCore.Application, as: CoreApp
  alias LemonCore.Capabilities

  @runtime_control [
    LemonCore.Drain,
    LemonCore.ACPClientBridge,
    LemonCore.NodeRegistry,
    LemonCore.RuntimeOwner,
    LemonCore.TerminalOutbox,
    LemonCore.SessionActivity,
    LemonCore.UsageLedger,
    LemonCore.ExecApprovalExpiry,
    LemonCore.ConfigReloader,
    LemonCore.ConfigReloader.Watcher
  ]

  setup do
    for key <- [:services, :required_capabilities, :store_runtime_override, :boot_mode] do
      previous = Application.fetch_env(:lemon_core, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:lemon_core, key, value)
          :error -> Application.delete_env(:lemon_core, key)
        end
      end)
    end

    :ok
  end

  describe "service groups" do
    test "every group starts when :services is unset" do
      Application.delete_env(:lemon_core, :services)
      assert CoreApp.service_groups() == [:core, :runtime_control, :run_history]
    end

    test ":core is always selected and the order is fixed" do
      Application.put_env(:lemon_core, :services, [:run_history])
      assert CoreApp.service_groups() == [:core, :run_history]

      Application.put_env(:lemon_core, :services, [])
      assert CoreApp.service_groups() == [:core]
    end

    test "an unknown group fails clearly" do
      Application.put_env(:lemon_core, :services, [:core, :browser])

      assert_raise ArgumentError,
                   ~r/unknown service groups \[:browser\]/,
                   &CoreApp.service_groups/0

      Application.put_env(:lemon_core, :services, :all)
      assert_raise ArgumentError, ~r/must be a list/, &CoreApp.service_groups/0
    end

    test "a [:core] runtime starts the store and none of the runtime's control services" do
      ids = ids(CoreApp.children(:runtime, [:core]))

      for core <- [LemonCore.RuntimeCache, LemonCore.Store, LemonCore.ConfigCache],
          do: assert(core in ids)

      for absent <- [LemonCore.RunHistoryStore | @runtime_control],
          do: refute(absent in ids, "[:core] starts #{inspect(absent)}")
    end

    test "each group adds exactly its services to the runtime tree" do
      core = ids(CoreApp.children(:runtime, [:core]))
      control = ids(CoreApp.children(:runtime, [:core, :runtime_control])) -- core
      history = ids(CoreApp.children(:runtime, [:core, :run_history])) -- core

      assert Enum.sort(control) == Enum.sort(@runtime_control)
      assert history == [LemonCore.RunHistoryStore]
    end

    test "every group is the full runtime tree" do
      assert CoreApp.children(:runtime, [:core, :runtime_control, :run_history]) ==
               CoreApp.children(:runtime)
    end
  end

  describe "capabilities" do
    test "nothing is required unless configured" do
      Application.delete_env(:lemon_core, :required_capabilities)
      assert Capabilities.required() == []
    end

    test "an unknown required capability fails clearly" do
      Application.put_env(:lemon_core, :required_capabilities, [:durable_store, :gpu])
      assert_raise ArgumentError, ~r/unknown capabilities \[:gpu\]/, &Capabilities.required/0
    end

    test ":durable_store needs a durable configured store backend" do
      Application.put_env(:lemon_core, :store_runtime_override,
        backend: LemonCore.Store.EtsBackend
      )

      assert {:error, {:missing_capability, :durable_store, reason}} =
               Capabilities.check([:durable_store], CoreApp.service_groups())

      assert reason =~ "LemonCore.Store.EtsBackend does not persist data"

      Application.put_env(:lemon_core, :store_runtime_override,
        backend: LemonCore.Store.SqliteBackend
      )

      assert Capabilities.check([:durable_store], CoreApp.service_groups()) == :ok
    end

    test "group capabilities need their group selected" do
      assert Capabilities.check([:run_history, :runtime_control], [
               :core,
               :runtime_control,
               :run_history
             ]) == :ok

      assert {:error, {:missing_capability, :run_history, reason}} =
               Capabilities.check([:runtime_control, :run_history], [:core, :runtime_control])

      assert reason =~ ":run_history service group is not selected"

      assert {:error, {:missing_capability, :runtime_control, _}} =
               Capabilities.check([:runtime_control], [:core, :run_history])
    end

    test "a runtime boot refuses to start without a required capability, before any process" do
      Application.put_env(:lemon_core, :boot_mode, :runtime)
      Application.put_env(:lemon_core, :services, [:core])
      Application.put_env(:lemon_core, :required_capabilities, [:runtime_control])

      log =
        capture_log(fn ->
          assert CoreApp.start(:normal, []) == {:error, {:missing_capability, :runtime_control}}
        end)

      assert log =~ "requires the :runtime_control capability"
    end

    test "one-shot client boots are not checked" do
      Application.put_env(:lemon_core, :boot_mode, :client)
      Application.put_env(:lemon_core, :services, [:core])
      Application.put_env(:lemon_core, :required_capabilities, [:runtime_control])

      # The check passes, so start/2 reaches the supervisor, which is already
      # running in the test VM.
      assert {:error, {:already_started, _}} = CoreApp.start(:normal, [])
    end
  end

  defp ids(children) do
    Enum.map(children, fn
      {module, _opts} when is_atom(module) -> module
      %{id: id} -> id
      module when is_atom(module) -> module
    end)
  end
end
