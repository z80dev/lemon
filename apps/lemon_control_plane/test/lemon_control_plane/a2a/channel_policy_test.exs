defmodule LemonControlPlane.A2A.ChannelPolicyTest do
  @moduledoc """
  A token-authenticated A2A peer's message, sent over the real A2A plug, must
  reach the router with `a2a` channel provenance derived from that peer. Its
  run gets the group approval floor unless the operator marks the peer
  `trusted_automation`, and the peer allow-list always intersects.
  """
  use ExUnit.Case, async: false

  import Plug.Conn

  alias LemonControlPlane.A2A.{Config, Router}
  alias LemonCore.{RateLimiter, RunRequest, ToolPolicy}
  alias LemonRouter.SubmissionBuilder

  @floor_tools ~w(bash write edit patch hashline_edit)

  defmodule CapturingOrchestrator do
    @behaviour LemonCore.RouterBridge.RunOrchestrator

    @impl true
    def submit(%RunRequest{} = request) do
      send(:persistent_term.get({__MODULE__, :owner}), {:a2a_policy_submit, request})
      {:error, :captured_for_policy_test}
    end
  end

  setup do
    previous_config = Application.get_env(:lemon_control_plane, :a2a_config)
    previous_bridge = Application.get_env(:lemon_core, :router_bridge)
    suffix = System.unique_integer([:positive])
    peer_id = "policy-peer-#{suffix}"
    trusted_id = "trusted-peer-#{suffix}"
    secret_name = "LEMON_TEST_A2A_POLICY_TOKEN_#{suffix}"
    trusted_secret_name = "LEMON_TEST_A2A_TRUSTED_TOKEN_#{suffix}"
    token = "a2a-policy-token-#{suffix}"
    trusted_token = "a2a-trusted-token-#{suffix}"
    System.put_env(secret_name, token)
    System.put_env(trusted_secret_name, trusted_token)
    :persistent_term.put({CapturingOrchestrator, :owner}, self())

    # Peers are normalized exactly as a `[gateway.a2a.peers.<id>]` table is.
    peers =
      Config.resolve(%{
        "peers" => %{
          peer_id => %{
            "inbound_token_secret" => secret_name,
            "allow_tools" => ["read", "bash"]
          },
          trusted_id => %{
            "inbound_token_secret" => trusted_secret_name,
            "allow_tools" => ["read", "bash"],
            "trusted_automation" => true
          }
        }
      }).peers

    Application.put_env(:lemon_control_plane, :a2a_config, %{
      host: "127.0.0.1",
      port: 9901,
      public_url: "http://127.0.0.1:9901",
      reply_timeout_ms: 1_000,
      rate_limit_per_minute: 100,
      max_context_turns: 100,
      peers: peers
    })

    :ok = LemonCore.RouterBridge.configure(run_orchestrator: CapturingOrchestrator)

    if is_nil(Process.whereis(LemonControlPlane.A2A.RateLimiter)) do
      start_supervised!(
        {RateLimiter,
         profile: :a2a,
         name: LemonControlPlane.A2A.RateLimiter,
         limit: fn -> LemonControlPlane.A2A.Config.current().rate_limit_per_minute end}
      )
    end

    on_exit(fn ->
      restore_env(:lemon_control_plane, :a2a_config, previous_config)
      restore_env(:lemon_core, :router_bridge, previous_bridge)
      System.delete_env(secret_name)
      System.delete_env(trusted_secret_name)
      :persistent_term.erase({CapturingOrchestrator, :owner})
    end)

    {:ok, peer_id: peer_id, token: token, trusted_token: trusted_token}
  end

  test "an authenticated peer's run carries a2a provenance derived from that peer", ctx do
    request = send_message(ctx.token, "hello")

    assert request.meta.a2a_peer_id == ctx.peer_id

    assert %{channel_id: "a2a", account_id: "lemon", peer_kind: :automation} =
             context = request.meta[:channel_context]

    # The provenance names the same conversation as the A2A session key.
    assert LemonCore.SessionKey.parse(request.session_key) |> Map.take([:peer_id, :thread_id]) ==
             Map.take(context, [:peer_id, :thread_id])
  end

  test "by configuration alone an allowed mutating tool still requires approval", ctx do
    policy = ctx.token |> send_message("please run a command") |> build_policy()

    assert ToolPolicy.allowed?(policy, "bash")

    for tool <- @floor_tools do
      assert policy.approvals[tool] == :always,
             "expected #{tool} to require approval for an untrusted peer, got #{inspect(policy)}"
    end
  end

  test "a trusted_automation peer runs without the approval floor", ctx do
    request = send_message(ctx.trusted_token, "please run a command")
    assert request.meta.channel_context.peer_kind == :dm

    policy = build_policy(request)

    assert ToolPolicy.allowed?(policy, "bash")
    for tool <- @floor_tools, do: assert(policy.approvals[tool] == nil)
    # The peer's own allow-list still applies.
    refute ToolPolicy.allowed?(policy, "write")
  end

  test "only a literal true marks a peer trusted_automation" do
    peers =
      Config.resolve(%{
        "peers" => %{
          "string" => %{"trusted_automation" => "true"},
          "unset" => %{},
          "literal" => %{"trusted_automation" => true}
        }
      }).peers

    assert peers["string"].trusted_automation == false
    assert peers["unset"].trusted_automation == false
    assert peers["literal"].trusted_automation == true
  end

  defp send_message(token, text) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => LemonCore.Id.uuid(),
      "method" => "SendMessage",
      "params" => %{
        "message" => %{
          "messageId" => LemonCore.Id.uuid7(),
          "contextId" => "policy-context-#{System.unique_integer([:positive])}",
          "role" => "ROLE_USER",
          "parts" => [%{"text" => text, "mediaType" => "text/plain"}]
        }
      }
    }

    # The router refuses non-loopback Host headers from loopback peers.
    response =
      %{Plug.Test.conn(:post, "/", Jason.encode!(body)) | host: "localhost"}
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Router.call([])

    assert response.status == 200
    assert_receive {:a2a_policy_submit, %RunRequest{} = request}, 2_000
    request
  end

  defp build_policy(%RunRequest{} = request) do
    assert {:ok, submission} =
             SubmissionBuilder.build(request, %{
               run_supervisor: LemonRouter.RunSupervisor,
               run_process_module: LemonRouter.RunProcess,
               run_process_opts: %{notify_pid: self()}
             })

    submission.execution_request.tool_policy
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
