defmodule LemonControlPlane.TuiSubagentsWireE2ETest do
  use ExUnit.Case, async: false

  alias CodingAgent.TaskStore
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @operator_token "tui-subagents-wire-operator-token"

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    key = "agent:default:tui:local:dm:hub-wire-#{suffix}"
    root = "hub-wire-root-#{suffix}"
    child_session = "hub-wire-child-#{suffix}"

    previous_provider = Application.get_env(:lemon_core, :agent_runtime_provider)
    previous_token = Application.get_env(:lemon_control_plane, :operator_token)

    previous_loopback =
      Application.get_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator)

    Application.put_env(:lemon_core, :agent_runtime_provider, CodingAgent.ControlPlaneProvider)
    Application.put_env(:lemon_control_plane, :operator_token, @operator_token)
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, false)
    :ok = LemonCore.ChatStateStore.put(key, %LemonCore.ChatState{last_resume_token: root})

    direct =
      TaskStore.new_task(%{
        owner: {root, "default"},
        session_key: key,
        parent_session_id: root,
        session_id: child_session,
        name: "Researcher",
        role: "scout",
        description: "Map the parser",
        prompt: "PRIVATE_PROMPT assignment body",
        status: :completed,
        agent_state: :parked,
        session_file: "/private/sessions/child.jsonl",
        cwd: "/private/worktree",
        result: %AgentToolResult{content: [%TextContent{text: "Parser mapped"}]}
      })

    nested =
      TaskStore.new_task(%{
        owner: {child_session, "default"},
        session_key: key,
        parent_session_id: child_session,
        description: "Nested check",
        status: :running
      })

    foreign =
      TaskStore.new_task(%{
        owner: {"another-root", "default"},
        session_key: key,
        parent_session_id: "another-root",
        description: "Another session's child",
        status: :running
      })

    on_exit(fn ->
      Enum.each([direct, nested, foreign], &TaskStore.delete_task/1)
      LemonCore.ChatStateStore.delete(key)
      restore(:lemon_core, :agent_runtime_provider, previous_provider)
      restore(:lemon_control_plane, :operator_token, previous_token)
      restore(:lemon_control_plane, :allow_unauthenticated_loopback_operator, previous_loopback)
    end)

    {:ok, suffix: suffix, key: key, direct: direct, nested: nested, foreign: foreign}
  end

  test "the production TUI hub crosses authenticated Bandit to the real task runtime", ctx do
    bun = System.find_executable("bun") || flunk("bun is required for the TUI wire proof")

    bandit =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: LemonControlPlane.HTTP.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: {:tui_subagents_wire_bandit, ctx.suffix},
          restart: :temporary
        )
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    repo_root = Path.expand("../../../..", __DIR__)
    proof_client = Path.join(repo_root, "clients/tui/scripts/subagents-wire-proof.ts")

    {output, status} =
      System.cmd(
        bun,
        [
          # Run against the lockfile-pinned clients/tui install, never auto-install.
          "--no-install",
          proof_client,
          "ws://127.0.0.1:#{port}/ws",
          @operator_token,
          ctx.key,
          ctx.direct,
          ctx.nested,
          ctx.foreign
        ],
        cd: repo_root,
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert {:ok, proof} = Jason.decode(String.trim(output))
    assert proof["ok"] == true
    assert length(proof["checks"]) == 6
    refute output =~ @operator_token
    refute output =~ "PRIVATE_PROMPT"

    # Refusals changed nothing: the foreign child still runs, the finished one stays finished.
    assert {:ok, %{status: :running}} = TaskStore.get_record(ctx.foreign)
    assert {:ok, %{status: :completed}} = TaskStore.get_record(ctx.direct)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
