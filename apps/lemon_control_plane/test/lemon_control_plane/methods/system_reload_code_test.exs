defmodule LemonControlPlane.Methods.SystemReloadCodeTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Methods.{Registry, SystemReloadCode}
  alias LemonControlPlane.Protocol.Schemas

  defmodule FakeReloader do
    def reload_modified(opts) do
      if Process.get(:reload_raise), do: raise("private failure /private/secret.beam")
      send(self(), {:reload_modified, opts})
      Process.get(:reload_initial, %{reloaded: [Initial], in_use: [Retried, Busy, Failed], failed: []})
    end

    def retry_in_use(modules) do
      send(self(), {:retry_in_use, modules})

      Process.get(:reload_retry, %{
        reloaded: [Retried],
        in_use: [Busy],
        failed: [{Failed, {:private_path, "/private/secret.beam"}}]
      })
    end
  end

  defmodule FakeRefresher do
    def refresh_sessions do
      send(self(), :refresh_sessions)
      %{refreshed: 2, busy: 1, failed: 3}
    end
  end

  setup do
    launcher = System.get_env("LEMON_CLI_LAUNCHER")
    keys = [:code_reloader, :code_reload_session_refresher]
    previous = Map.new(keys, &{&1, Application.fetch_env(:lemon_control_plane, &1)})
    System.put_env("LEMON_CLI_LAUNCHER", "source")
    Application.put_env(:lemon_control_plane, :code_reloader, FakeReloader)
    Application.put_env(:lemon_control_plane, :code_reload_session_refresher, FakeRefresher)

    on_exit(fn ->
      if launcher,
        do: System.put_env("LEMON_CLI_LAUNCHER", launcher),
        else: System.delete_env("LEMON_CLI_LAUNCHER")

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:lemon_control_plane, key, value)
        {key, :error} -> Application.delete_env(:lemon_control_plane, key)
      end)
    end)

    :ok
  end

  test "registered method requires admin and rejects read, write and node callers" do
    assert SystemReloadCode.name() in Registry.list_methods()
    assert Authorize.required_scopes(SystemReloadCode.name()) == [:admin]
    assert SystemReloadCode.scopes() == [:admin]

    for auth <- [
          %{role: :operator, scopes: [:read]},
          %{role: :operator, scopes: [:write]},
          %{role: :node, scopes: [:invoke, :event]}
        ] do
      assert {:error, {:forbidden, _}} =
               Registry.dispatch(SystemReloadCode.name(), %{}, %{auth: auth})
    end

    refute_received {:reload_modified, _}
  end

  test "refuses missing and packaged launcher markers before any reload" do
    for launcher <- [nil, "release", "", "SOURCE"] do
      if launcher,
        do: System.put_env("LEMON_CLI_LAUNCHER", launcher),
        else: System.delete_env("LEMON_CLI_LAUNCHER")

      assert {:error, {:unavailable, _}} = SystemReloadCode.handle(%{}, %{})
    end

    refute_received {:reload_modified, _}
    refute_received :refresh_sessions
    refute_received {:retry_in_use, _}
  end

  test "validates the exact supported parameter shape" do
    assert :ok = Schemas.validate(SystemReloadCode.name(), %{})
    assert :ok = Schemas.validate(SystemReloadCode.name(), %{"sessions" => false})
    assert {:error, _} = Schemas.validate(SystemReloadCode.name(), %{"sessions" => "true"})

    for params <- [nil, [], true, %{"sessions" => nil}, %{"sessions" => 1}, %{"other" => true}] do
      assert {:error, {:invalid_request, _}} = SystemReloadCode.handle(params, %{})
    end

    refute_received {:reload_modified, _}
  end

  test "reloads, refreshes by default, retries once and replaces original in-use results" do
    assert :code.get_mode() == :interactive

    assert {:ok, result} =
             Registry.dispatch(SystemReloadCode.name(), %{}, %{
               auth: %{role: :operator, scopes: [:admin]}
             })

    assert_received {:reload_modified, []}
    assert_received :refresh_sessions
    assert_received {:retry_in_use, [Retried, Busy, Failed]}
    refute_received {:retry_in_use, _}
    assert result["reloaded"] == ["Elixir.Initial", "Elixir.Retried"]
    assert result["inUse"] == ["Elixir.Busy"]
    assert result["failed"] == [%{"module" => "Elixir.Failed", "reason" => "load_failed"}]
    assert result["reloadedCount"] == 2
    assert result["inUseCount"] == 1
    assert result["failedCount"] == 1
    assert result["sessions"] == %{"refreshed" => 2, "busy" => 1, "failed" => 3}
    refute Jason.encode!(result) =~ "/private"
  end

  test "sessions false skips refresh but still retries and returns zero session counts" do
    assert {:ok, result} = SystemReloadCode.handle(%{"sessions" => false}, %{})
    assert_received {:reload_modified, []}
    assert_received {:retry_in_use, _}
    refute_received :refresh_sessions
    assert result["sessions"] == %{"refreshed" => 0, "busy" => 0, "failed" => 0}
  end

  test "unexpected reload failures never expose raw terms or paths" do
    Process.put(:reload_raise, true)
    assert {:error, {:unavailable, message}} = SystemReloadCode.handle(%{}, %{})
    assert message == "Code reload failed; some changes may already have been applied."
    refute_received :refresh_sessions
    refute_received {:retry_in_use, _}
  end

  test "bounds each module list at 200 while preserving exact counts and safe failures" do
    modules = for index <- 1..205, do: Module.concat(__MODULE__, "Fixture#{index}")
    Process.put(:reload_initial, %{reloaded: modules, in_use: modules, failed: []})

    Process.put(:reload_retry, %{
      reloaded: [],
      in_use: modules,
      failed: Enum.map(modules, &{&1, :badfile})
    })

    assert {:ok, result} = SystemReloadCode.handle(%{"sessions" => false}, %{})

    for {list, count} <- [
          {"reloaded", "reloadedCount"},
          {"inUse", "inUseCount"},
          {"failed", "failedCount"}
        ] do
      assert length(result[list]) == 200
      assert result[count] == 205
    end

    assert Enum.all?(result["failed"], &(&1["reason"] == "badfile"))
    assert is_binary(Jason.encode!(result))
  end
end
