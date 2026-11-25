defmodule LemonControlPlane.A2A.PeerScopeTest do
  @moduledoc """
  Outbound `peer` conversations are owned by one `{agent_id, session_key}` and
  are exercised here over a real A2A HTTP listener.
  """

  use ExUnit.Case, async: false

  alias LemonAgent.Types.AgentToolResult
  alias LemonControlPlane.A2A.Router
  alias LemonCore.RateLimiter
  alias LemonSkills.Tools.Peer

  defmodule RunStub do
    # Echoes the wrapped prompt so the outbound transcript proves which text
    # reached the peer in which conversation.
    def submit(request) do
      Task.start(fn ->
        topic = LemonCore.Bus.run_done_topic(request.run_id)
        await_subscriber(topic, System.monotonic_time(:millisecond) + 5_000)
        answer = "echo: " <> request.prompt

        LemonCore.Bus.broadcast(topic, %{
          type: :run_completed,
          payload: %{completed: %{run_id: request.run_id, ok: true, answer: answer}}
        })
      end)

      {:ok, request.run_id}
    end

    defp await_subscriber(topic, deadline) do
      registry = if LemonCore.Bus.pubsub?(), do: LemonCore.PubSub, else: LemonCore.Bus.Registry

      if Registry.lookup(registry, topic) == [] and System.monotonic_time(:millisecond) < deadline do
        Process.sleep(5)
        await_subscriber(topic, deadline)
      end
    end
  end

  setup do
    previous_loopback =
      Application.get_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator)

    previous_config = Application.get_env(:lemon_control_plane, :a2a_config)
    previous_bridge = Application.get_env(:lemon_core, :router_bridge)
    previous_peers = Application.get_env(:lemon_skills, :a2a_peers)

    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, true)

    Application.put_env(:lemon_control_plane, :a2a_config, %{
      host: "127.0.0.1",
      port: 9901,
      public_url: "http://127.0.0.1:9901",
      peers: %{},
      reply_timeout_ms: 1_000,
      rate_limit_per_minute: 100,
      max_context_turns: 100
    })

    :ok = LemonCore.RouterBridge.configure(run_orchestrator: RunStub)

    if is_nil(Process.whereis(LemonControlPlane.A2A.RateLimiter)) do
      start_supervised!(
        {RateLimiter,
         profile: :a2a,
         name: LemonControlPlane.A2A.RateLimiter,
         limit: fn -> LemonControlPlane.A2A.Config.current().rate_limit_per_minute end}
      )
    end

    bandit =
      start_supervised!(
        {Bandit, plug: Router, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    peer_id = "hermes-scope-#{System.unique_integer([:positive])}"

    Application.put_env(:lemon_skills, :a2a_peers, %{
      peer_id => %{
        id: peer_id,
        url: "http://127.0.0.1:#{port}",
        token_secret: nil,
        outbound_token_secret: nil,
        timeout_ms: 2_000,
        capabilities: []
      }
    })

    on_exit(fn ->
      restore(:lemon_control_plane, :allow_unauthenticated_loopback_operator, previous_loopback)
      restore(:lemon_control_plane, :a2a_config, previous_config)
      restore(:lemon_core, :router_bridge, previous_bridge)
      restore(:lemon_skills, :a2a_peers, previous_peers)
    end)

    %{peer_id: peer_id}
  end

  test "sessions under different agents each see only their own peer conversation", %{
    peer_id: peer_id
  } do
    alice = session_tool("alice", "agent:alice:main")
    bob = session_tool("bob", "agent:bob:main")

    a1 = ok!(call(alice, %{"action" => "message", "peer_id" => peer_id, "text" => "alpha-1"}))
    b1 = ok!(call(bob, %{"action" => "message", "peer_id" => peer_id, "text" => "bravo-1"}))
    a2 = ok!(call(alice, %{"action" => "message", "peer_id" => peer_id, "text" => "alpha-2"}))

    assert a1["context_id"] == a2["context_id"]
    assert a2["turn_count"] == 2
    refute b1["context_id"] == a1["context_id"]
    assert b1["turn_count"] == 1

    alice_history = ok!(call(alice, %{"action" => "history", "peer_id" => peer_id}))
    alice_transcript = transcript(alice_history)
    assert alice_transcript =~ "alpha-1" and alice_transcript =~ "alpha-2"
    refute alice_transcript =~ "bravo-1"

    bob_history = ok!(call(bob, %{"action" => "history", "peer_id" => peer_id}))
    bob_transcript = transcript(bob_history)
    assert bob_transcript =~ "bravo-1"
    refute bob_transcript =~ "alpha-"

    listed = ok!(call(bob, %{"action" => "list"}))
    [listed_peer] = Enum.filter(listed["peers"], &(&1["id"] == peer_id))
    assert listed_peer["default_context_id"] == b1["context_id"]
  end

  test "a foreign context_id or task_id is denied, not served", %{peer_id: peer_id} do
    alice = session_tool("alice", "agent:alice:main")
    mallory = session_tool("mallory", "agent:mallory:main")
    same_agent_other_session = session_tool("alice", "agent:alice:other")

    a1 = ok!(call(alice, %{"action" => "message", "peer_id" => peer_id, "text" => "secret"}))
    alice_task = a1["task"]["id"]
    assert is_binary(alice_task)

    for intruder <- [mallory, same_agent_other_session] do
      assert {:error, reason} =
               call(intruder, %{
                 "action" => "history",
                 "peer_id" => peer_id,
                 "context_id" => a1["context_id"]
               })

      assert reason =~ "context"

      assert {:error, task_reason} =
               call(intruder, %{
                 "action" => "status",
                 "peer_id" => peer_id,
                 "task_id" => alice_task
               })

      assert task_reason =~ "task"

      assert {:error, _} =
               call(intruder, %{
                 "action" => "cancel",
                 "peer_id" => peer_id,
                 "task_id" => alice_task
               })
    end

    assert %{"task" => %{"id" => ^alice_task}} =
             ok!(
               call(alice, %{"action" => "status", "peer_id" => peer_id, "task_id" => alice_task})
             )
  end

  test "a tool without a session identity fails closed", %{peer_id: peer_id} do
    tool = Peer.tool(File.cwd!(), [])

    assert {:error, reason} =
             call(tool, %{"action" => "message", "peer_id" => peer_id, "text" => "orphan"})

    assert reason =~ "session"
  end

  test "inbound A2A never serves legacy outbound tasks or outbound transcripts" do
    # Loopback callers authenticate as peer "local"; seed records under that id.
    legacy_id = "legacy-out-#{System.unique_integer([:positive])}"

    :ok =
      LemonCore.Store.put(LemonCore.Store, :a2a_tasks, legacy_id, %{
        id: legacy_id,
        direction: :outbound,
        peer_id: "local",
        context_id: "legacy-ctx",
        run_id: nil,
        state: "TASK_STATE_COMPLETED",
        answer: "legacy outbound answer",
        error: nil,
        created_at_ms: 1,
        updated_at_ms: 1
      })

    for method <- ~w(GetTask CancelTask SubscribeToTask) do
      response = rpc(method, %{"id" => legacy_id})

      assert get_in(response, ["error", "message"]) == "Task not found",
             inspect({method, response})
    end

    listed = rpc("ListTasks", %{"pageSize" => 100})
    refute Enum.any?(listed["result"]["tasks"], &(&1["id"] == legacy_id))

    colliding = "outbound-ctx-#{System.unique_integer([:positive])}"

    {:ok, _} =
      LemonCore.A2AStore.append_message(%{
        direction: :outbound,
        peer_id: "local",
        context_id: colliding,
        role: "ROLE_AGENT",
        text: "outbound-only secret"
      })

    sent =
      rpc("SendMessage", %{
        "message" => %{
          "messageId" => LemonCore.Id.uuid7(),
          "contextId" => colliding,
          "role" => "ROLE_USER",
          "parts" => [%{"text" => "inbound hello", "mediaType" => "text/plain"}]
        }
      })

    task = sent["result"]["task"]
    assert task["contextId"] == colliding
    rendered = Jason.encode!(task)
    assert rendered =~ "inbound hello"
    refute rendered =~ "outbound-only secret"

    fetched = rpc("GetTask", %{"id" => task["id"]})
    refute Jason.encode!(fetched) =~ "outbound-only secret"
  end

  defp rpc(method, params) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => LemonCore.Id.uuid(),
      "method" => method,
      "params" => params
    }

    # The router refuses non-loopback Host headers from loopback peers.
    response =
      %{Plug.Test.conn(:post, "/", Jason.encode!(body)) | host: "localhost"}
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call([])

    if response.status == 200 and
         Plug.Conn.get_resp_header(response, "content-type") |> Enum.any?(&(&1 =~ "json")),
       do: Jason.decode!(response.resp_body),
       else: %{"status" => response.status, "raw" => response.resp_body}
  end

  defp session_tool(agent_id, session_key),
    do: Peer.tool(File.cwd!(), agent_id: agent_id, session_key: session_key)

  defp call(tool, params), do: tool.execute.("call-#{System.unique_integer()}", params, nil, nil)

  defp ok!(%AgentToolResult{trust: :untrusted, details: details}), do: details
  defp ok!(other), do: flunk("expected a peer result, got: #{inspect(other)}")

  defp transcript(%{"messages" => messages}), do: Enum.map_join(messages, "\n", & &1["text"])

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
