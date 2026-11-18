defmodule LemonControlPlane.A2A.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test, except: [conn: 2, conn: 3]

  alias LemonControlPlane.A2A.{Router}
  alias LemonCore.RateLimiter

  defmodule RunStub do
    def submit(request) do
      owner = :persistent_term.get({__MODULE__, :owner})
      answer = :persistent_term.get({__MODULE__, :answer}, "hello from Lemon")
      send(owner, {:a2a_submitted, request})

      Task.start(fn ->
        topic = LemonCore.Bus.run_topic(request.run_id)
        await_subscriber(topic, System.monotonic_time(:millisecond) + 5_000)

        LemonCore.Bus.broadcast(topic, %{
          type: :run_completed,
          payload: %{completed: %{run_id: request.run_id, ok: true, answer: answer}}
        })
      end)

      {:ok, request.run_id}
    end

    # The A2A runner subscribes to the run topic only after `submit/1` returns, so the
    # completion must wait for that subscription instead of guessing a delay.
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

    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, true)
    on_exit(fn -> restore_env(:allow_unauthenticated_loopback_operator, previous_loopback) end)
    previous_config = Application.get_env(:lemon_control_plane, :a2a_config)
    previous_bridge = Application.get_env(:lemon_core, :router_bridge)
    :persistent_term.put({RunStub, :owner}, self())
    :persistent_term.put({RunStub, :answer}, "hello from Lemon")

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

    on_exit(fn ->
      restore_env(:a2a_config, previous_config)

      if previous_bridge,
        do: Application.put_env(:lemon_core, :router_bridge, previous_bridge),
        else: Application.delete_env(:lemon_core, :router_bridge)

      :persistent_term.erase({RunStub, :owner})
      :persistent_term.erase({RunStub, :answer})
    end)

    :ok
  end

  test "tokenless local peers require the explicit compatibility flag" do
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, false)
    assert {:error, :unauthorized} = LemonControlPlane.A2A.Auth.authenticate(conn(:post, "/"))

    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, true)
    assert {:ok, "local"} = LemonControlPlane.A2A.Auth.authenticate(conn(:post, "/"))

    remote = %{conn(:post, "/") | remote_ip: {192, 168, 1, 9}}
    assert {:error, :unauthorized} = LemonControlPlane.A2A.Auth.authenticate(remote)
  end

  test "publishes an A2A v1.0 Agent Card" do
    response = :get |> conn("/.well-known/agent-card.json") |> Router.call([])
    card = Jason.decode!(response.resp_body)

    assert response.status == 200

    assert card["supportedInterfaces"] == [
             %{
               "url" => "http://127.0.0.1:9901",
               "protocolBinding" => "JSONRPC",
               "protocolVersion" => "1.0"
             }
           ]

    assert card["capabilities"]["streaming"] == true
  end

  test "keeps repeated SendMessage calls in one private Lemon session" do
    context_id = "friendship-#{System.unique_integer([:positive])}"

    first = send_message(context_id, "hello")

    assert first["result"]["task"]["status"]["state"] == "TASK_STATE_COMPLETED",
           inspect(first)

    assert get_in(first, ["result", "task", "status", "message", "parts", Access.at(0), "text"]) ==
             "hello from Lemon"

    assert_receive {:a2a_submitted, first_request}

    second = send_message(context_id, "what were we discussing?")
    assert second["result"]["task"]["contextId"] == context_id
    assert_receive {:a2a_submitted, second_request}

    assert first_request.session_key == second_request.session_key
    assert first_request.session_key =~ ":a2a:lemon:dm:"
    refute first_request.session_key =~ context_id
    assert first_request.prompt =~ "EXTERNAL_UNTRUSTED_CONTENT"
    assert first_request.meta.a2a_peer_id == "local"
  end

  test "does not allow tokenless loopback fallback when peer authentication is configured" do
    Application.put_env(:lemon_control_plane, :a2a_config, %{
      peers: %{
        "hermes" => %{
          id: "hermes",
          inbound_token_secret: "a2a/hermes",
          token_secret: nil
        }
      }
    })

    body = %{
      "jsonrpc" => "2.0",
      "id" => "auth-test",
      "method" => "ListTasks",
      "params" => %{}
    }

    response =
      :post
      |> conn("/", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> Router.call([])

    assert response.status == 401
  end

  test "the peer tool resumes one context over the real HTTP wire" do
    bandit =
      start_supervised!(
        {Bandit, plug: Router, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)

    peer = %{
      id: "hermes-wire",
      url: "http://127.0.0.1:#{port}",
      token_secret: nil,
      outbound_token_secret: nil,
      timeout_ms: 1_000,
      capabilities: ["coordination"]
    }

    Application.put_env(:lemon_skills, :a2a_peers, %{"hermes-wire" => peer})
    on_exit(fn -> Application.delete_env(:lemon_skills, :a2a_peers) end)

    assert %LemonAgent.Types.AgentToolResult{trust: :untrusted, details: first} =
             LemonSkills.Tools.Peer.execute(
               "call-1",
               %{"action" => "message", "peer_id" => "hermes-wire", "text" => "hello"},
               nil,
               nil
             )

    assert %LemonAgent.Types.AgentToolResult{trust: :untrusted, details: second} =
             LemonSkills.Tools.Peer.execute(
               "call-2",
               %{
                 "action" => "message",
                 "peer_id" => "hermes-wire",
                 "text" => "continue"
               },
               nil,
               nil
             )

    assert first["context_id"] == second["context_id"]
    assert first["turn_count"] == 1
    assert second["turn_count"] == 2
    assert second["answer"] == "hello from Lemon"
  end

  defp send_message(context_id, text) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => LemonCore.Id.uuid(),
      "method" => "SendMessage",
      "params" => %{
        "message" => %{
          "messageId" => LemonCore.Id.uuid7(),
          "contextId" => context_id,
          "role" => "ROLE_USER",
          "parts" => [%{"text" => text, "mediaType" => "text/plain"}]
        }
      }
    }

    response =
      :post
      |> conn("/", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> Router.call([])

    assert response.status == 200
    Jason.decode!(response.resp_body)
  end

  test "rebound Host cannot reach authenticated message/send over the real listener" do
    bandit =
      start_supervised!(
        {Bandit, plug: Router, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "rebind",
        "method" => "message/send",
        "params" => %{
          "message" => %{
            "messageId" => LemonCore.Id.uuid7(),
            "contextId" => "rebind-#{System.unique_integer([:positive])}",
            "role" => "ROLE_USER",
            "parts" => [%{"text" => "pwn", "mediaType" => "text/plain"}]
          }
        }
      })

    for host <- ["attacker.example:#{port}", "evil.localhost:#{port}"] do
      assert raw_post(port, host, body) =~ "HTTP/1.1 403", host
      refute_receive {:a2a_submitted, _}, 100
    end

    assert raw_post(port, "127.0.0.1:#{port}", body) =~ "HTTP/1.1 200"
    assert_receive {:a2a_submitted, _}, 2_000
  end

  test "Host from a path-bearing public_url is trusted; unrelated hosts are not" do
    config = Application.get_env(:lemon_control_plane, :a2a_config)

    Application.put_env(
      :lemon_control_plane,
      :a2a_config,
      Map.put(config, :public_url, "https://Agent.Example/a2a")
    )

    bandit =
      start_supervised!(
        {Bandit, plug: Router, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    get = &"GET /healthz HTTP/1.1\r\nHost: #{&1}\r\nConnection: close\r\n\r\n"

    assert raw(port, get.("agent.example")) =~ "HTTP/1.1 200"
    assert raw(port, get.("agent.example:443")) =~ "HTTP/1.1 200"
    assert raw(port, get.("other.example")) =~ "HTTP/1.1 403"
  end

  defp raw(port, request) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)

    try do
      :ok = :gen_tcp.send(socket, request)
      {:ok, response} = :gen_tcp.recv(socket, 0, 5_000)
      response
    after
      :gen_tcp.close(socket)
    end
  end

  defp raw_post(port, host, body) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)

    try do
      :ok =
        :gen_tcp.send(
          socket,
          "POST / HTTP/1.1\r\nHost: #{host}\r\nContent-Type: application/json\r\n" <>
            "Content-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
        )

      {:ok, response} = :gen_tcp.recv(socket, 0, 5_000)
      response
    after
      :gen_tcp.close(socket)
    end
  end

  # The router refuses non-loopback Host headers from loopback peers.
  defp conn(method, path, body \\ nil),
    do: %{Plug.Test.conn(method, path, body) | host: "localhost"}

  defp restore_env(key, nil), do: Application.delete_env(:lemon_control_plane, key)
  defp restore_env(key, value), do: Application.put_env(:lemon_control_plane, key, value)
end
