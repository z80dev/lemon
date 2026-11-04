defmodule LemonControlPlane.Methods.NamedAgentsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{
    AgentIdentityList,
    AgentIdentityRegister,
    AgentIdentityRename,
    AgentIdentityUnregister,
    AgentMessageSend,
    AgentMessageGet,
    AgentMessageComplete
  }

  alias LemonControlPlane.WS.Connection

  defp context(pid \\ self(), scopes \\ [:admin]),
    do: %{auth: %{role: :operator, scopes: scopes}, conn_pid: pid}

  defp unique, do: Integer.to_string(System.unique_integer([:positive]))

  test "role and scope checks reject nodes, peers and unprivileged scope selection" do
    for role <- [:node, :a2a, :enrollment] do
      ctx = %{auth: %{role: role, scopes: [:admin, :read, :write]}, conn_pid: self()}
      assert {:error, {:forbidden, _, _}} = AgentIdentityList.handle(%{}, ctx)

      assert {:error, {:forbidden, _, _}} =
               AgentMessageComplete.handle(%{"messageId" => "x", "status" => "completed"}, ctx)
    end

    assert {:error, {:forbidden, _, _}} =
             AgentIdentityList.handle(%{"scope" => "bot:other:owner"}, context(self(), [:read]))

    assert {:error, {:forbidden, _, _}} =
             AgentIdentityRegister.handle(%{}, context(self(), [:write]))

    assert {:error, {:forbidden, _, _}} =
             AgentIdentityRename.handle(
               %{"id" => "bot://x/y", "name" => "bob"},
               context(self(), [:read])
             )
  end

  test "malformed requests fail before routing, including nullable rename presence" do
    for params <- [
          %{"limit" => 0},
          %{"limit" => 201},
          %{"limit" => 1.5},
          %{"query" => String.duplicate("x", 257)},
          %{"scope" => nil},
          %{"scope" => String.duplicate("x", 257)}
        ] do
      assert {:error, {:invalid_request, _, _}} = AgentIdentityList.handle(params, context())
    end

    assert {:error, {:invalid_request, _, _}} =
             AgentIdentityRename.handle(%{"id" => "bot://x/y"}, context())

    assert {:error, {:invalid_request, _, _}} =
             AgentIdentityRename.handle(
               %{"id" => "bot://x/y", "name" => "not a handle"},
               context()
             )

    base = %{"sourceId" => "bot://x/a", "target" => "@bob", "text" => "hello", "messageId" => "m"}

    for params <- [
          Map.put(base, "text", String.duplicate("x", 32769)),
          Map.put(base, "messageId", ""),
          Map.put(base, "sourceId", nil),
          Map.put(base, "conn_pid", "forged")
        ] do
      assert {:error, {:invalid_request, _, _}} = AgentMessageSend.handle(params, context())
    end

    assert {:error, {:invalid_request, _, _}} =
             AgentMessageComplete.handle(
               %{
                 "messageId" => "m",
                 "status" => "completed",
                 "response" => String.duplicate("x", 32769)
               },
               context()
             )

    assert {:error, {:invalid_request, _, _}} =
             AgentMessageComplete.handle(
               %{
                 "messageId" => "m",
                 "status" => "completed",
                 "error" => "secret exception details"
               },
               context()
             )
  end

  test "external requests and completion are exact-connection targeted and private" do
    tag = unique()
    scope = "bot:rpc-test:#{tag}"
    source = "bot://rpc-test/source-#{tag}"
    target = "bot://rpc-test/target-#{tag}"
    parent = self()
    target_pid = spawn(fn -> relay(parent) end)
    bystander = spawn(fn -> relay(parent) end)

    on_exit(fn ->
      Process.exit(target_pid, :kill)
      Process.exit(bystander, :kill)
    end)

    for {id, pid} <- [{source, self()}, {target, target_pid}] do
      assert {:ok, %{"agent" => agent}} =
               AgentIdentityRegister.handle(
                 %{
                   "scope" => scope,
                   "id" => id,
                   "metadata" => %{"botId" => List.last(String.split(id, "/"))}
                 },
                 context(pid)
               )

      assert agent["id"] == id
      refute Map.has_key?(agent, "scope")
      refute Map.has_key?(agent, "metadata")
    end

    on_exit(fn ->
      LemonCore.AgentIdentity.remove(scope, source)
      LemonCore.AgentIdentity.remove(scope, target)
    end)

    assert {:ok, %{"agent" => %{"id" => ^target, "name" => "bob"}}} =
             AgentIdentityRename.handle(
               %{"scope" => scope, "id" => target, "name" => "Bob"},
               context()
             )

    assert {:ok, %{"agents" => agents}} =
             AgentIdentityList.handle(%{"scope" => scope}, context())

    assert Enum.sort(Enum.map(agents, & &1["id"])) == Enum.sort([source, target])

    assert {:ok, %{"agents" => [%{"id" => ^target}]}} =
             AgentIdentityList.handle(%{"scope" => scope, "query" => "bob"}, context())

    collision =
      AgentIdentityRename.handle(%{"scope" => scope, "id" => source, "name" => "bob"}, context())

    assert {:error, {:conflict, _, _}} = collision

    frame =
      LemonControlPlane.Protocol.Frames.encode_response("collision", collision) |> Jason.decode!()

    assert %{
             "ok" => false,
             "error" => %{
               "code" => "CONFLICT",
               "details" => %{"retrySafe" => true, "mutationMayHaveApplied" => false}
             }
           } = frame

    assert {:ok, %{"agent" => %{"id" => ^target, "name" => "bob"}}} =
             AgentIdentityRename.handle(
               %{"scope" => scope, "id" => target, "name" => "bob"},
               context()
             )

    message_id = "rpc-#{tag}"

    params = %{
      "scope" => scope,
      "sourceId" => source,
      "target" => "@bob",
      "text" => "private question",
      "messageId" => message_id
    }

    assert {:error, {:forbidden, _, %{"retrySafe" => true, "mutationMayHaveApplied" => false}}} =
             AgentMessageSend.handle(params, context(bystander))

    assert {:ok, %{"status" => "accepted", "targetId" => ^target}} =
             AgentMessageSend.handle(params, context())

    assert_receive {:relayed, ^target_pid,
                    {:named_agent_event, "agent.message.request",
                     %{"messageId" => ^message_id, "text" => "private question"}}}

    refute_receive {:relayed, ^bystander, _}
    refute_receive {:named_agent_event, "agent.message.request", _}

    complete = %{
      "messageId" => message_id,
      "status" => "completed",
      "response" => "visible answer"
    }

    assert {:error, {:forbidden, _, _}} =
             AgentMessageComplete.handle(complete, context(bystander))

    assert {:ok, %{"status" => "completed", "response" => "visible answer"}} =
             AgentMessageComplete.handle(complete, context(target_pid))

    assert_receive {:named_agent_event, "agent.message.result",
                    %{"messageId" => ^message_id, "status" => "completed"}}

    refute_receive {:relayed, ^bystander, _}

    assert {:ok, %{"status" => "completed"}} =
             AgentMessageGet.handle(
               %{"scope" => scope, "sourceId" => source, "messageId" => message_id},
               context()
             )

    assert {:error, _} =
             AgentMessageGet.handle(
               %{"scope" => scope, "sourceId" => target, "messageId" => message_id},
               context()
             )

    assert {:error, _} =
             AgentMessageSend.handle(Map.put(params, "text", "different intent"), context())

    assert {:error, {:forbidden, _, _}} =
             AgentIdentityUnregister.handle(
               %{"scope" => scope, "id" => target},
               context(bystander)
             )

    assert {:ok, %{"removed" => true}} =
             AgentIdentityUnregister.handle(
               %{"scope" => scope, "id" => target},
               context(target_pid)
             )

    assert {:ok, %{"removed" => true}} =
             AgentIdentityUnregister.handle(%{"scope" => scope, "id" => source}, context())
  end

  test "targeted events use the existing connection sequence and reject nonoperators" do
    state = %Connection{
      connected: true,
      auth: %{role: :operator},
      event_seq: 4,
      state_version: %{}
    }

    payload = %{"messageId" => "private", "text" => "body"}

    assert {:push, {:text, frame}, state} =
             Connection.handle_info({:named_agent_event, "agent.message.request", payload}, state)

    assert %{"seq" => 5, "event" => "agent.message.request", "payload" => ^payload} =
             Jason.decode!(frame)

    assert {:push, {:text, frame}, _} = Connection.handle_info({:event, "presence", %{}}, state)
    assert %{"seq" => 6} = Jason.decode!(frame)

    for role <- [:node, :a2a, :enrollment] do
      state = %{state | auth: %{role: role}}

      assert {:ok, ^state} =
               Connection.handle_info(
                 {:named_agent_event, "agent.message.request", payload},
                 state
               )
    end
  end

  test "offline identities fail without fallback and unknown completion remains uncertain" do
    tag = unique()
    scope = "bot:rpc-offline:#{tag}"
    source = "bot://rpc-offline/source-#{tag}"
    target = "bot://rpc-offline/target-#{tag}"

    assert {:ok, _} =
             AgentIdentityRegister.handle(
               %{"scope" => scope, "id" => source, "metadata" => %{}},
               context()
             )

    assert {:ok, _} =
             LemonCore.AgentIdentity.register(scope, target, %{kind: :bot, metadata: %{}})

    on_exit(fn ->
      LemonCore.AgentIdentity.remove(scope, source)
      LemonCore.AgentIdentity.remove(scope, target)
    end)

    params = %{
      "scope" => scope,
      "sourceId" => source,
      "target" => target,
      "text" => "hello",
      "messageId" => "offline-#{tag}"
    }

    assert {:error,
            {:unavailable, _,
             %{"reason" => "offline", "retrySafe" => true, "mutationMayHaveApplied" => false}}} =
             AgentMessageSend.handle(params, context())

    assert {:ok, _} =
             AgentIdentityRegister.handle(
               %{"scope" => scope, "id" => target, "metadata" => %{}},
               context()
             )

    message_id = "unknown-#{tag}"

    assert {:ok, %{"status" => "accepted"}} =
             AgentMessageSend.handle(%{params | "messageId" => message_id}, context())

    assert_receive {:named_agent_event, "agent.message.request", %{"messageId" => ^message_id}}

    assert {:ok, %{"status" => "outcome_unknown"}} =
             AgentMessageComplete.handle(
               %{"messageId" => message_id, "status" => "outcome_unknown"},
               context()
             )

    assert {:ok, %{"status" => "outcome_unknown"}} =
             AgentMessageGet.handle(
               %{"scope" => scope, "sourceId" => source, "messageId" => message_id},
               context()
             )

    assert {:ok, _} =
             AgentIdentityUnregister.handle(%{"scope" => scope, "id" => target}, context())

    assert {:ok, _} =
             AgentIdentityUnregister.handle(%{"scope" => scope, "id" => source}, context())
  end

  test "an unavailable runtime is not reported as an empty roster or successful send" do
    LemonCore.AgentMessaging.configure(nil)

    try do
      assert {:error,
              {:unavailable, _,
               %{
                 "reason" => "unavailable",
                 "retrySafe" => true,
                 "mutationMayHaveApplied" => false
               }}} =
               AgentIdentityList.handle(%{}, context())

      assert {:error,
              {:unavailable, _, %{"retrySafe" => true, "mutationMayHaveApplied" => false}}} =
               AgentMessageSend.handle(
                 %{
                   "sourceId" => "bot://missing/source",
                   "target" => "@bob",
                   "text" => "hello",
                   "messageId" => unique()
                 },
                 context()
               )
    after
      LemonCore.AgentMessaging.configure(LemonRouter.AgentMessaging)
    end
  end

  defp relay(parent) do
    receive do
      message ->
        send(parent, {:relayed, self(), message})
        relay(parent)
    end
  end
end
