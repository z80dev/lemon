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

  setup do
    ensure_registry_started()
    cleanup_test_methods()
    :ok
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

  test "dispatch/3 rescues handler exceptions and returns internal_error" do
    method = register_for_cleanup(RaisingHandler)
    ctx = ctx_with_scopes([])

    assert {:error, {:internal_error, "Method execution failed", "boom from registry test"}} =
             Registry.dispatch(method, %{}, ctx)
  end

  test "dispatch/3 returns method_not_found for unknown method" do
    unknown_method = "#{@test_method_prefix}unknown.#{System.unique_integer([:positive])}"
    ctx = ctx_with_scopes([])

    assert {:error, {:method_not_found, "Unknown method: " <> ^unknown_method}} =
             Registry.dispatch(unknown_method, %{}, ctx)
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
