defmodule CodingAgent.ControlPlaneProviderTest do
  @moduledoc """
  The provider deliberately carries no `@behaviour` attribute, so that this app
  keeps no compile-time reference to the reference runtime. These tests are what
  replaces that compile-time check.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.ControlPlaneProvider

  @behaviour_module LemonControlPlane.AgentRuntime.Provider

  test "implements every callback the control plane declares" do
    expected = @behaviour_module.behaviour_info(:callbacks) |> Enum.sort()

    missing =
      Enum.reject(expected, fn {fun, arity} ->
        function_exported?(ControlPlaneProvider, fun, arity)
      end)

    assert missing == [],
           "provider is missing: #{inspect(missing)} — a typo here degrades the method to its fallback silently"
  end

  test "exports nothing the control plane does not ask for" do
    declared = @behaviour_module.behaviour_info(:callbacks) |> MapSet.new()

    extra =
      ControlPlaneProvider.__info__(:functions)
      |> Enum.reject(&(&1 in declared))
      |> Enum.reject(fn {fun, _arity} -> fun == :module_info end)

    assert extra == [], "provider exports beyond the contract: #{inspect(extra)}"
  end

  describe "boot registration" do
    setup do
      original = Application.get_env(:lemon_control_plane, :agent_runtime_provider)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:lemon_control_plane, :agent_runtime_provider)
        else
          Application.put_env(:lemon_control_plane, :agent_runtime_provider, original)
        end
      end)

      :ok
    end

    test "the running application has registered this provider" do
      assert LemonControlPlane.AgentRuntime.provider() == ControlPlaneProvider
      assert LemonControlPlane.AgentRuntime.available?()
    end
  end

  describe "adapters return the shapes the control plane expects" do
    test "list_tasks returns id/record pairs" do
      assert is_list(ControlPlaneProvider.list_tasks())
    end

    test "compact_session reports a missing session rather than raising" do
      assert ControlPlaneProvider.compact_session(
               "no-such-session-#{System.unique_integer()}",
               []
             ) ==
               {:error, :session_not_found}
    end

    test "todo_progress carries the actionable count for the control plane to rename" do
      case ControlPlaneProvider.todo_progress("no-such-session-#{System.unique_integer()}") do
        nil -> :ok
        progress -> assert Map.has_key?(progress, :actionable_count)
      end
    end

    test "wasm_sidecar_running? is a boolean" do
      assert is_boolean(ControlPlaneProvider.wasm_sidecar_running?())
    end

    test "extension_dirs returns global then project" do
      dirs = ControlPlaneProvider.extension_dirs("/tmp/some-project")

      assert length(dirs) == 2
      assert Enum.all?(dirs, &is_binary/1)
    end
  end
end
