defmodule LemonControlPlane.Methods.NodeProfilePathsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{NodeProfilePaths, Registry}
  alias LemonControlPlane.NodeStore

  setup do
    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)

    if Process.whereis(LemonCore.NodeRegistry) == nil,
      do: start_supervised!(LemonCore.NodeRegistry)

    :ok
  end

  test "registered operator-read lookup does not accept node callers or caller paths" do
    assert Registry.lookup("node.profile.paths") == {:ok, NodeProfilePaths}
    assert Registry.dispatch_mode("node.profile.paths") == :async
    assert NodeProfilePaths.scopes() == [:read]
    params = %{"nodeId" => "destination", "profileId" => "selected"}

    assert {:error, {:forbidden, _}} =
             NodeProfilePaths.handle(params, %{auth: %{role: :node, scopes: [:read]}})

    assert {:error, {:forbidden, _}} =
             NodeProfilePaths.handle(params, %{auth: %{role: :operator, scopes: [:write]}})

    assert {:error, {:invalid_request, _}} =
             NodeProfilePaths.handle(
               Map.put(params, "workspacePath", "/caller/guess"),
               ctx(self())
             )

    assert {:error, {:invalid_request, _}} =
             NodeProfilePaths.handle(%{params | "profileId" => "../escape"}, ctx(self()))
  end

  test "lookup binds durable target and returns only acknowledged destination paths" do
    owner = self()
    {id, target} = register_node(owner, :target)
    {_shadow_id, _shadow} = register_node(owner, :shadow, id)
    params = %{"nodeId" => id, "profileId" => "selected"}
    request = Task.async(fn -> NodeProfilePaths.handle(params, ctx(owner)) end)
    assert_receive {:target, {:node_event, "node.invoke.request", payload}}
    assert payload["nodeId"] == id
    assert payload["method"] == "node.profile.paths"
    assert payload["args"] == %{"profileId" => "selected"}
    refute_receive {:shadow, {:node_event, "node.invoke.request", _}}, 50

    result = %{
      "profileId" => "selected",
      "workspacePath" => "/destination/custom/profiles/selected/workspace",
      "skillsPath" => "/destination/custom/profiles/selected/workspace/.lemon/skill"
    }

    assert :ok =
             LemonCore.NodeRegistry.complete_session(
               id,
               target,
               0,
               payload["invokeId"],
               result,
               nil
             )

    assert Task.await(request) == {:ok, Map.put(result, "nodeId", id)}
    LemonCore.NodeRegistry.unregister(id, target)
    assert {:error, {:unavailable, _}} = NodeProfilePaths.handle(params, ctx(owner))
    refute_receive {:shadow, {:node_event, "node.invoke.request", _}}, 50
  end

  test "wrong ownership or malformed destination path acknowledgment is unavailable" do
    owner = self()
    {id, target} = register_node(owner, :target)

    for result <- [
          %{
            "profileId" => "other",
            "workspacePath" => "/destination/workspace",
            "skillsPath" => "/destination/workspace/.lemon/skill"
          },
          %{
            "profileId" => "selected",
            "workspacePath" => "relative/workspace",
            "skillsPath" => "relative/workspace/.lemon/skill"
          },
          %{
            "profileId" => "selected",
            "workspacePath" => "/destination/workspace",
            "skillsPath" => "/caller/guess"
          }
        ] do
      request =
        Task.async(fn ->
          NodeProfilePaths.handle(%{"nodeId" => id, "profileId" => "selected"}, ctx(owner))
        end)

      assert_receive {:target, {:node_event, "node.invoke.request", payload}}

      assert :ok =
               LemonCore.NodeRegistry.complete_session(
                 id,
                 target,
                 0,
                 payload["invokeId"],
                 result,
                 nil
               )

      assert {:error, {:unavailable, _}} = Task.await(request)
    end
  end

  defp register_node(owner, label, name \\ nil) do
    id = "profile-paths-#{label}-#{System.unique_integer([:positive])}"
    name = name || id
    pid = spawn(fn -> forward(owner, label) end)

    assert :ok =
             NodeStore.put_node(id, %{
               id: id,
               name: name,
               type: "coding_agent",
               capabilities: %{"node.profile.paths" => true},
               status: :offline
             })

    assert :ok = LemonCore.NodeRegistry.register(id, name, pid)

    on_exit(fn ->
      LemonCore.NodeRegistry.unregister(id, pid)
      LemonCore.Store.delete(:nodes_registry, id)
      LemonCore.Store.delete(:nodes_by_name, name)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    {id, pid}
  end

  defp forward(owner, label) do
    receive do
      message ->
        send(owner, {label, message})
        forward(owner, label)
    end
  end

  defp ctx(owner), do: %{auth: %{role: :operator, scopes: [:read]}, conn_pid: owner}
end
