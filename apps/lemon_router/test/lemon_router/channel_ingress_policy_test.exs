defmodule LemonRouter.ChannelIngressPolicyTest do
  @moduledoc """
  Real channel ingress (`LemonChannels.Runtime.submit_inbound/2` ->
  `LemonChannels.RunRequestBuilder` -> `LemonCore.RouterBridge.submit_run/1`)
  must carry enough context for the channel policy, the group approval floor,
  sender identity and the channel cwd default to apply when the run is built.
  """
  use ExUnit.Case, async: false

  alias LemonCore.{InboundMessage, RunRequest}
  alias LemonCore.RouterBridge
  alias LemonRouter.SubmissionBuilder

  @gateway_config_key :"Elixir.LemonGateway.Config"

  defmodule CapturingOrchestrator do
    @behaviour LemonCore.RouterBridge.RunOrchestrator

    @impl true
    def submit(%RunRequest{} = request) do
      send(Application.fetch_env!(:lemon_router, :channel_ingress_test_pid), {:submit, request})
      {:ok, request.run_id || "run_channel_ingress"}
    end
  end

  setup do
    previous_bridge = Application.get_env(:lemon_core, :router_bridge)
    previous_gateway = Application.get_env(:lemon_gateway, @gateway_config_key)
    previous_agent_dir = System.get_env("LEMON_AGENT_DIR")

    agent_dir =
      Path.join(System.tmp_dir!(), "lemon_channel_ingress_#{System.unique_integer([:positive])}")

    :ok = RouterBridge.configure([run_orchestrator: CapturingOrchestrator], mode: :merge)
    Application.put_env(:lemon_router, :channel_ingress_test_pid, self())
    # No configured gateway.default_cwd: channel runs must fall back to the assistant home.
    Application.put_env(:lemon_gateway, @gateway_config_key, %{default_cwd: nil})
    System.put_env("LEMON_AGENT_DIR", agent_dir)

    on_exit(fn ->
      restore_app_env(:lemon_core, :router_bridge, previous_bridge)
      restore_app_env(:lemon_gateway, @gateway_config_key, previous_gateway)
      Application.delete_env(:lemon_router, :channel_ingress_test_pid)

      if previous_agent_dir,
        do: System.put_env("LEMON_AGENT_DIR", previous_agent_dir),
        else: System.delete_env("LEMON_AGENT_DIR")

      File.rm_rf(agent_dir)
    end)

    {:ok, agent_dir: agent_dir}
  end

  test "a Telegram group message requires approval for every mutating tool" do
    tool_policy = build_submission(peer_kind: :group, peer_id: "-100123").tool_policy

    for tool <- ~w(bash write edit patch hashline_edit) do
      assert tool_policy.approvals[tool] == :always,
             "expected #{tool} to require approval in a group, got #{inspect(tool_policy)}"
    end
  end

  test "a channel_policies row changes the effective policy of a real ingress run" do
    LemonCore.PolicyStore.put_channel("telegram", %{blocked_tools: ["browser"]})
    on_exit(fn -> LemonCore.Store.delete(:channel_policies, "telegram") end)

    tool_policy = build_submission(peer_kind: :dm, peer_id: "4250").tool_policy

    assert "browser" in tool_policy.blocked_tools
  end

  test "a Telegram DM is not subject to the group approval policy" do
    tool_policy = build_submission(peer_kind: :dm, peer_id: "4242").tool_policy

    assert tool_policy.approvals["bash"] == nil
    assert tool_policy.approvals["edit"] == nil
  end

  test "caller-supplied meta cannot replace the ingress channel context" do
    tool_policy =
      build_submission(
        peer_kind: :group,
        peer_id: "-100124",
        meta: %{channel_context: %{channel_id: "telegram", peer_kind: :dm}}
      ).tool_policy

    assert tool_policy.approvals["bash"] == :always
  end

  test "channel runs default to the assistant home, not $HOME", %{agent_dir: agent_dir} do
    execution = build_submission(peer_kind: :dm, peer_id: "4243")
    assistant_home = Path.join(agent_dir, "workspace") |> Path.expand()

    assert execution.cwd == assistant_home
    assert File.dir?(assistant_home)
    refute execution.cwd == System.user_home()
  end

  test "transport sender identity overrides caller metadata and reaches run memory" do
    command =
      build_submission(
        peer_kind: :dm,
        peer_id: "4244",
        sender: %{id: "99", bot: true},
        meta: %{
          channel_identity: %{
            channel_id: "forged",
            sender_id: "another",
            is_bot: false,
            owner?: true
          }
        }
      )

    identity = %{
      channel_id: "telegram",
      sender_id: "99",
      is_bot: true,
      owner?: false,
      verified?: true
    }

    assert command.meta.channel_identity == identity

    doc =
      LemonMemory.Document.from_run(command.run_id, %{}, %{
        session_key: command.session_key,
        agent_id: command.meta.agent_id,
        meta: command.meta
      })

    assert doc.meta.channel_identity == identity
  end

  test "transport owner attestation reaches execution while channel access alone does not" do
    owner = build_submission(peer_kind: :dm, peer_id: "4245", sender: %{id: "99", owner?: true})
    assert owner.meta.channel_identity.owner? == true
    non_owner = build_submission(peer_kind: :group, peer_id: "-4245", sender: %{id: "100"})
    assert non_owner.meta.channel_identity.owner? == false
  end

  test "an unknown or missing peer kind fails closed to the group approval floor" do
    for kind <- [nil, :thread, "group"] do
      tool_policy = build_submission(peer_kind: kind, peer_id: "-4260").tool_policy

      for tool <- ~w(bash write edit patch hashline_edit) do
        assert tool_policy.approvals[tool] == :always,
               "expected #{tool} to require approval for peer kind #{inspect(kind)}"
      end
    end
  end

  test "a sender without a transport id gets an unverified per-peer identity, never the owner" do
    command = build_submission(peer_kind: :channel, peer_id: "-100777", sender: nil)
    identity = command.meta.channel_identity

    assert identity == %{
             channel_id: "telegram",
             sender_id: "unidentified:channel:-100777",
             is_bot: false,
             owner?: false,
             verified?: false
           }
  end

  test "an email From is unverified: no owner attestation and no existing memory peer" do
    command =
      build_submission(
        channel_id: "email",
        peer_kind: :dm,
        peer_id: "owner@example.test",
        sender: %{id: "owner@example.test", owner?: true}
      )

    assert command.meta.channel_identity == %{
             channel_id: "email",
             sender_id: "owner@example.test",
             is_bot: false,
             owner?: false,
             verified?: false
           }
  end

  for channel <- ["telegram", "discord"] do
    test "a #{channel} /new memory reflection in a group keeps the channel policy and floor" do
      channel = unquote(channel)
      chat_id = System.unique_integer([:positive])

      session_key =
        LemonCore.SessionKey.channel_peer(%{
          agent_id: "default",
          channel_id: channel,
          account_id: "default",
          peer_kind: :group,
          peer_id: "-#{chat_id}"
        })

      LemonCore.PolicyStore.put_channel(channel, %{blocked_tools: ["browser"]})

      on_exit(fn ->
        LemonCore.Store.delete(:channel_policies, channel)
        LemonCore.RunStore.delete_history(session_key)
      end)

      :ok =
        LemonCore.RunHistoryStore.put(session_key, System.system_time(:millisecond), "h1", %{
          run_id: "h1",
          session_key: session_key,
          summary: %{prompt: "remember this", completed: %{answer: "ok"}}
        })

      inbound = %InboundMessage{
        channel_id: channel,
        account_id: "default",
        peer: %{kind: :group, id: "-#{chat_id}", thread_id: nil},
        sender: %{id: "100", owner?: false},
        message: %{id: "1", text: "/new", timestamp: nil, reply_to_id: nil},
        raw: %{},
        meta: %{agent_id: "default", channel_context: %{channel_id: "x", peer_kind: :dm}}
      }

      assert :ok =
               LemonChannels.Adapters.Telegram.Transport.MemoryReflection.submit_before_new(
                 %{account_id: "default"},
                 inbound,
                 %LemonCore.ChatScope{transport: String.to_atom(channel), chat_id: chat_id},
                 session_key,
                 chat_id,
                 nil,
                 nil,
                 %{
                   maybe_subscribe_to_run: fn _ -> :ok end,
                   current_thread_generation: fn _, _, _ -> 0 end,
                   maybe_put: fn map, key, value -> Map.put(map, key, value) end
                 }
               )

      assert_receive {:submit, %RunRequest{origin: :channel} = request}
      execution = build_execution(request)

      for tool <- ~w(bash write edit patch hashline_edit) do
        assert execution.tool_policy.approvals[tool] == :always
      end

      assert "browser" in execution.tool_policy.blocked_tools
      assert execution.meta.channel_identity.sender_id == "100"
    end
  end

  test "a colon-bearing email reference still threads the reply to the original reference" do
    command =
      build_submission(
        channel_id: "email",
        peer_kind: :dm,
        peer_id: "alice@example.test",
        thread_id: "root:a:b@x.test"
      )

    assert {:ok, route} =
             LemonRouter.DeliveryRouteResolver.resolve(command.session_key, "email", command.meta)

    assert route.channel_id == "email"
    assert route.peer_id == "alice@example.test"
    assert route.thread_id == "root:a:b@x.test"

    forged = put_in(command.meta, [:peer, :thread_id], "other:thread@x.test")

    assert :error =
             LemonRouter.DeliveryRouteResolver.resolve(command.session_key, "email", forged)
  end

  test "a hashed account id is restored only from matching retained provenance" do
    key =
      LemonCore.SessionKey.channel_peer(%{
        agent_id: "default",
        channel_id: "email",
        account_id: "acct:1",
        peer_kind: :dm,
        peer_id: "alice@example.test"
      })

    meta = %{account_id: "acct:1", peer: %{kind: :dm, id: "alice@example.test", thread_id: nil}}

    assert {:ok, route} = LemonRouter.DeliveryRouteResolver.resolve(key, "email", meta)
    assert route.account_id == "acct:1"
    assert route.peer_id == "alice@example.test"

    assert :error =
             LemonRouter.DeliveryRouteResolver.resolve(key, "email", %{meta | account_id: "other"})

    assert :error = LemonRouter.DeliveryRouteResolver.resolve(key, "email", %{})
  end

  test "a channel request without trusted provenance is refused at admission" do
    legacy = %RunRequest{
      run_id: "run_legacy_#{System.unique_integer([:positive])}",
      origin: :channel,
      session_key: "agent:default:telegram:default:group:-1:new_reflection",
      agent_id: "default",
      prompt: "reflect",
      meta: %{channel_id: "telegram", peer: %{kind: :group, id: "-1"}, sender: %{id: "9"}}
    }

    for request <- [
          legacy,
          put_in(legacy.meta[:channel_context], %{channel_id: "telegram", peer_kind: :group}),
          put_in(legacy.meta[:channel_identity], %{channel_id: "telegram", sender_id: "9"})
        ] do
      assert {:error, :missing_channel_provenance} =
               SubmissionBuilder.build(request, %{
                 run_supervisor: LemonRouter.RunSupervisor,
                 run_process_module: LemonRouter.RunProcess,
                 run_process_opts: %{notify_pid: self()}
               })
    end
  end

  defp build_submission(opts) do
    msg = %InboundMessage{
      channel_id: Keyword.get(opts, :channel_id, "telegram"),
      peer: %{
        kind: Keyword.fetch!(opts, :peer_kind),
        id: Keyword.fetch!(opts, :peer_id),
        thread_id: Keyword.get(opts, :thread_id)
      },
      account_id: "default",
      sender: Keyword.get(opts, :sender, %{id: "99"}),
      message: %{id: "1", text: "please edit the file", timestamp: nil, reply_to_id: nil},
      raw: %{},
      meta: Map.merge(%{agent_id: "default"}, Keyword.get(opts, :meta, %{}))
    }

    assert :ok = LemonChannels.Runtime.submit_inbound(msg)
    assert_receive {:submit, %RunRequest{origin: :channel} = request}
    build_execution(request)
  end

  defp build_execution(request) do
    request = %{request | run_id: request.run_id || "run_#{System.unique_integer([:positive])}"}

    assert {:ok, submission} =
             SubmissionBuilder.build(request, %{
               run_supervisor: LemonRouter.RunSupervisor,
               run_process_module: LemonRouter.RunProcess,
               run_process_opts: %{notify_pid: self()}
             })

    submission.execution_request
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
