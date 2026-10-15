defmodule LemonRouter.ChannelIngressPolicyTest do
  @moduledoc """
  Real channel ingress (`Router.handle_inbound/1`) must carry enough context
  for the channel policy and the channel cwd default to apply when the run is
  built.
  """
  use ExUnit.Case, async: false

  alias LemonCore.{InboundMessage, RunRequest}
  alias LemonRouter.{Router, SubmissionBuilder}

  @gateway_config_key :"Elixir.LemonGateway.Config"

  defmodule CapturingOrchestrator do
    def submit(%RunRequest{} = request) do
      send(Application.fetch_env!(:lemon_router, :channel_ingress_test_pid), {:submit, request})
      {:ok, "run_channel_ingress"}
    end
  end

  setup do
    previous_orchestrator = Application.get_env(:lemon_router, :run_orchestrator)
    previous_gateway = Application.get_env(:lemon_gateway, @gateway_config_key)
    previous_agent_dir = System.get_env("LEMON_AGENT_DIR")

    agent_dir =
      Path.join(System.tmp_dir!(), "lemon_channel_ingress_#{System.unique_integer([:positive])}")

    Application.put_env(:lemon_router, :run_orchestrator, CapturingOrchestrator)
    Application.put_env(:lemon_router, :channel_ingress_test_pid, self())
    # No configured gateway.default_cwd: channel runs must fall back to the assistant home.
    Application.put_env(:lemon_gateway, @gateway_config_key, %{default_cwd: nil})
    System.put_env("LEMON_AGENT_DIR", agent_dir)

    on_exit(fn ->
      restore_app_env(:lemon_router, :run_orchestrator, previous_orchestrator)
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
        meta: %{channel_identity: %{channel_id: "forged", sender_id: "another", is_bot: false}}
      )

    identity = %{channel_id: "telegram", sender_id: "99", is_bot: true}
    assert command.meta.channel_identity == identity

    doc =
      LemonMemory.Document.from_run(command.run_id, %{}, %{
        session_key: command.session_key,
        agent_id: command.meta.agent_id,
        meta: command.meta
      })

    assert doc.meta.channel_identity == identity
  end

  defp build_submission(opts) do
    msg = %InboundMessage{
      channel_id: "telegram",
      peer: %{
        kind: Keyword.fetch!(opts, :peer_kind),
        id: Keyword.fetch!(opts, :peer_id),
        thread_id: nil
      },
      account_id: "default",
      sender: Keyword.get(opts, :sender, %{id: "99"}),
      message: %{id: "1", text: "please edit the file", timestamp: nil, reply_to_id: nil},
      raw: %{},
      meta: Map.merge(%{agent_id: "default"}, Keyword.get(opts, :meta, %{}))
    }

    assert :ok = Router.handle_inbound(msg)
    assert_receive {:submit, %RunRequest{origin: :channel} = request}

    request = %{request | run_id: "run_#{System.unique_integer([:positive])}"}

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
