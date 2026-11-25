defmodule LemonControlPlane.Methods.RegistryTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.Registry

  @test_method_prefix "registry.test."

  defmodule LifecycleHandler do
    @behaviour LemonControlPlane.Method
    @method "registry.test.lifecycle"

    @impl true
    def name, do: @method

    @impl true
    def scopes, do: []

    @impl true
    def handle(_params, _ctx), do: {:ok, %{"lifecycle" => true}}
  end

  defmodule PublicDispatchHandler do
    @behaviour LemonControlPlane.Method
    @method "registry.test.dispatch.public"

    @impl true
    def name, do: @method

    @impl true
    def scopes, do: []

    @impl true
    def handle(params, ctx) do
      {:ok, %{"echo" => params || %{}, "connId" => ctx.conn_id}}
    end
  end

  defmodule AdminScopedHandler do
    @behaviour LemonControlPlane.Method
    @method "registry.test.dispatch.admin"

    @impl true
    def name, do: @method

    @impl true
    def scopes, do: [:admin]

    @impl true
    def handle(_params, _ctx), do: {:ok, %{"unexpected" => true}}
  end

  defmodule RaisingHandler do
    @behaviour LemonControlPlane.Method
    @method "registry.test.dispatch.raise"

    @impl true
    def name, do: @method

    @impl true
    def scopes, do: []

    @impl true
    def handle(_params, _ctx), do: raise("boom from registry test")
  end

  defmodule WriteRaisingHandler do
    @behaviour LemonControlPlane.Method
    @method "registry.test.dispatch.write_raise"

    @impl true
    def name, do: @method

    @impl true
    def scopes, do: [:write]

    @impl true
    def handle(_params, _ctx), do: raise("boom after a possible write")
  end

  setup do
    ensure_registry_started()
    cleanup_test_methods()
    :ok
  end

  test "canonical usage records is advertised as a read-only method" do
    assert {:ok, LemonControlPlane.Methods.UsageRecords} = Registry.lookup("usage.records")
    assert "usage.records" in Registry.list_methods()
    assert LemonControlPlane.Methods.UsageRecords.scopes() == [:read]
  end

  test "channel pairing requires pairing scope and a trusted local operator context" do
    assert {:ok, LemonControlPlane.Methods.ChannelPairing} = Registry.lookup("channels.pairing")

    assert {:error, {:forbidden, _}} =
             Registry.dispatch(
               "channels.pairing",
               %{"action" => "list"},
               ctx_with_scopes([:read])
             )

    ctx = ctx_with_scopes([:pairing]) |> Map.put(:local?, false)

    assert {:error, :forbidden, "Local operator access required", nil} =
             Registry.dispatch("channels.pairing", %{"action" => "list"}, ctx)

    assert {:error, :forbidden, _, nil} =
             Registry.dispatch(
               "channels.pairing",
               %{"action" => "list", "local?" => true},
               ctx
             )
  end

  test "register/1, lookup/1, unregister/1, and list_methods/0 for dynamic method names" do
    method = LifecycleHandler.name()
    refute method in Registry.list_methods()

    register_for_cleanup(LifecycleHandler)

    assert {:ok, LifecycleHandler} = Registry.lookup(method)
    assert method in Registry.list_methods()

    assert :ok = Registry.unregister(method)
    assert {:error, :not_found} = Registry.lookup(method)
    refute method in Registry.list_methods()
  end

  test "dispatch/3 success path for public methods" do
    method = register_for_cleanup(PublicDispatchHandler)
    params = %{"payload" => "ok"}
    ctx = ctx_with_scopes([])

    assert {:ok, %{"echo" => ^params, "connId" => "registry-test-conn"}} =
             Registry.dispatch(method, params, ctx)
  end

  test "dispatch/3 denies authorization when required scope is missing" do
    method = register_for_cleanup(AdminScopedHandler)
    ctx = ctx_with_scopes([:read])

    assert {:error, {:forbidden, "Insufficient permissions for " <> ^method}} =
             Registry.dispatch(method, %{}, ctx)
  end

  test "dispatch/3 rescues handler exceptions without returning private exception messages" do
    method = register_for_cleanup(RaisingHandler)
    ctx = ctx_with_scopes([])

    assert {:error, {:internal_error, "Method execution failed"}} =
             Registry.dispatch(method, %{}, ctx)
  end

  test "dispatch/3 marks a crashed write-scope method as not retry-safe" do
    method = register_for_cleanup(WriteRaisingHandler)
    read_only = register_for_cleanup(RaisingHandler)

    assert {:error, {:internal_error, "Method execution failed", %{"retrySafe" => false}}} =
             Registry.dispatch(method, %{}, ctx_with_scopes([:write]))

    assert {:internal_error, "Method execution failed"} = Registry.execution_failure(read_only)
  end

  test "unknown method names are omitted from telemetry" do
    unknown_method = "private-token-unknown-method"
    attach_method_telemetry()
    assert {:error, _} = Registry.dispatch(unknown_method, %{}, ctx_with_scopes([]))
    assert_receive {:method_telemetry, :start, %{system_time: time}, %{method: :unknown}}
    assert is_integer(time)
    assert_receive {:method_telemetry, :stop, %{duration: duration}, metadata}
    assert is_integer(duration) and duration >= 0
    assert metadata == %{method: :unknown, outcome: :error}
  end

  test "real dispatch emits content-free native timing for success, error and exception" do
    attach_method_telemetry()

    for {handler, outcome} <- [
          {PublicDispatchHandler, :ok},
          {AdminScopedHandler, :error},
          {RaisingHandler, :exception}
        ] do
      method = register_for_cleanup(handler)
      Registry.dispatch(method, %{"token" => "private-param"}, ctx_with_scopes([]))
      assert_receive {:method_telemetry, :start, %{system_time: time}, %{method: ^method}}
      assert is_integer(time)
      assert_receive {:method_telemetry, :stop, %{duration: duration}, metadata}
      assert is_integer(duration) and duration >= 0
      assert metadata == %{method: method, outcome: outcome}
    end
  end

  test "status callback redacts state, current message and failure reason" do
    status = %{
      state: %{table: "secret-table"},
      message: {:register, "secret-message"},
      reason: {:error, "secret-reason"}
    }

    assert Registry.format_status(status) == %{
             state: %{module: Registry},
             message: :redacted,
             reason: :redacted,
             log: []
           }
  end

  defp attach_method_telemetry do
    id = {__MODULE__, make_ref()}
    events = for event <- [:start, :stop], do: [:lemon, :control_plane, :method, event]
    :ok = :telemetry.attach_many(id, events, &__MODULE__.capture_method_telemetry/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  def capture_method_telemetry([:lemon, :control_plane, :method, event], values, metadata, pid) do
    send(pid, {:method_telemetry, event, values, metadata})
  end

  test "dispatch/3 returns method_not_found for unknown method" do
    unknown_method = "#{@test_method_prefix}unknown.#{System.unique_integer([:positive])}"
    ctx = ctx_with_scopes([])

    assert {:error, {:method_not_found, "Unknown method: " <> ^unknown_method}} =
             Registry.dispatch(unknown_method, %{}, ctx)
  end

  test "removed uncalled method families answer method_not_found while client methods stay registered" do
    ctx = ctx_with_scopes([:admin, :read, :write, :approvals, :pairing])

    for removed <- ~w(kanban.board.list tts.status wizard.start device.pair.request
                      lsp.server.start checkpoint.diff secrets.list proofs.status send
                      config.get config.set) do
      assert {:error, {:method_not_found, "Unknown method: " <> ^removed}} =
               Registry.dispatch(removed, %{}, ctx)
    end

    methods = Registry.list_methods()

    for kept <- ~w(chat.send sessions.list profile.chat blueprints.list connect.challenge
                   node.pair.request node.invoke.result exec.approval.resolve usage.status) do
      assert kept in methods
    end
  end

  defp ensure_registry_started do
    case Process.whereis(Registry) do
      nil -> start_supervised!(Registry)
      _pid -> :ok
    end
  end

  defp register_for_cleanup(module) do
    method = module.name()
    :ok = Registry.register(module)

    on_exit(fn ->
      case Process.whereis(Registry) do
        pid when is_pid(pid) ->
          case Registry.unregister(method) do
            :ok -> :ok
            {:error, :not_found} -> :ok
          end

        _ ->
          :ok
      end
    end)

    method
  end

  defp cleanup_test_methods do
    case Process.whereis(Registry) do
      pid when is_pid(pid) ->
        Registry.list_methods()
        |> Enum.filter(&String.starts_with?(&1, @test_method_prefix))
        |> Enum.each(fn method ->
          case Registry.unregister(method) do
            :ok -> :ok
            {:error, :not_found} -> :ok
          end
        end)

      _ ->
        :ok
    end
  end

  defp ctx_with_scopes(scopes) do
    %{
      conn_id: "registry-test-conn",
      conn_pid: self(),
      auth: %{
        role: :operator,
        scopes: scopes,
        token: nil,
        client_id: nil,
        identity: nil
      }
    }
  end
end
