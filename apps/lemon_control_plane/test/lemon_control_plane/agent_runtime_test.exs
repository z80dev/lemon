defmodule LemonControlPlane.AgentRuntimeTest do
  # Mutates the provider registration, so it must not run alongside other tests.
  use ExUnit.Case, async: false

  alias LemonControlPlane.AgentRuntime

  defmodule FullProvider do
    def list_tasks, do: [{"task-1", %{status: :running}}]
    def get_task("task-1"), do: {:ok, %{status: :running}, []}
    def get_task(_), do: :not_found
    def wasm_sidecar_running?, do: true
  end

  defmodule PartialProvider do
    def list_tasks, do: [{"task-2", %{}}]
  end

  defmodule RaisingProvider do
    def list_tasks, do: raise("boom")
    def wasm_sidecar_running?, do: exit(:dead)
  end

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

  defp use_provider(module),
    do: Application.put_env(:lemon_control_plane, :agent_runtime_provider, module)

  defp no_provider, do: Application.delete_env(:lemon_control_plane, :agent_runtime_provider)

  describe "registration" do
    test "register/1 makes a provider available" do
      no_provider()
      refute AgentRuntime.available?()

      assert AgentRuntime.register(FullProvider) == :ok

      assert AgentRuntime.provider() == FullProvider
      assert AgentRuntime.available?()
    end

    test "register/1 refuses a module that cannot be loaded" do
      no_provider()

      assert AgentRuntime.register(Definitely.Not.Loaded) == {:error, :not_a_provider}
      refute AgentRuntime.available?()
    end

    test "registration is readable as plain config" do
      use_provider(FullProvider)

      assert AgentRuntime.provider() == FullProvider
    end
  end

  describe "call/3 degradation" do
    test "serves the call when the provider implements it" do
      use_provider(FullProvider)

      assert AgentRuntime.call(:list_tasks, [], []) == [{"task-1", %{status: :running}}]

      assert AgentRuntime.call(:get_task, ["task-1"], :unavailable) ==
               {:ok, %{status: :running}, []}
    end

    test "falls back with no provider registered" do
      no_provider()

      assert AgentRuntime.call(:list_tasks, [], []) == []
      assert AgentRuntime.call(:get_task, ["task-1"], :unavailable) == :unavailable
      assert AgentRuntime.call(:wasm_sidecar_running?, [], false) == false
    end

    test "falls back for a callback the provider does not implement" do
      use_provider(PartialProvider)

      assert AgentRuntime.call(:list_tasks, [], []) == [{"task-2", %{}}]
      assert AgentRuntime.call(:run_graph, ["run-1"], :unavailable) == :unavailable
    end

    test "falls back when the provider raises" do
      use_provider(RaisingProvider)

      assert AgentRuntime.call(:list_tasks, [], []) == []
    end

    test "falls back when the provider exits" do
      use_provider(RaisingProvider)

      assert AgentRuntime.call(:wasm_sidecar_running?, [], false) == false
    end
  end

  describe "methods without an agent runtime" do
    setup do
      no_provider()
      :ok
    end

    test "tasks.active.list answers with an empty list, not an error" do
      assert {:ok, payload} = LemonControlPlane.Methods.TasksActiveList.handle(%{}, %{})
      assert payload["tasks"] == []
    end

    test "tasks.recent.list answers with an empty list" do
      assert {:ok, payload} = LemonControlPlane.Methods.TasksRecentList.handle(%{}, %{})
      assert payload["tasks"] == []
    end

    test "sessions.compact reports the runtime as unavailable, in the pre-existing shape" do
      assert {:error, {:internal_error, "Failed to compact session", reason}} =
               LemonControlPlane.Methods.SessionsCompact.handle(
                 %{"sessionKey" => "agent:main:x"},
                 %{}
               )

      assert reason == :session_registry_not_available
    end
  end
end
