defmodule CodingAgent.Tools.TaskIdentityTest do
  @moduledoc """
  A task child's routing identity comes only from the launching session's
  captured options. Model-supplied `session_key`/`agent_id` cannot redirect
  completions into another conversation or let the child act as another
  owner (for example, through the session-scoped `peer` tool).
  """

  use ExUnit.Case, async: false

  alias CodingAgent.Session.State
  alias CodingAgent.Tools.Task
  alias CodingAgent.Tools.Task.Params
  alias LemonCore.{RunRequest}
  alias LemonSkills.A2AStore

  @parent_key "agent:main:main"
  @decoy_key "agent:victim:main"

  defmodule RouterSpy do
    def submit(%RunRequest{} = request) do
      send(:persistent_term.get({__MODULE__, :owner}), {:router_submit, request})
      {:ok, "run_spy"}
    end
  end

  defmodule StreamingSessionSpy do
    def handle_async_followup(pid, message) do
      send(pid, {:session_async_followup, State.build_async_followup_message(message)})
      :ok
    end

    def get_state(_pid), do: %{is_streaming: true}
  end

  setup do
    :persistent_term.put({RouterSpy, :owner}, self())
    on_exit(fn -> :persistent_term.erase({RouterSpy, :owner}) end)
    :ok
  end

  test "routing overrides are rejected and no completion reaches the decoy session" do
    overrides = [
      %{"session_key" => @decoy_key, "agent_id" => "victim"},
      %{"session_key" => @decoy_key},
      %{"agent_id" => "victim"},
      %{"queue_mode" => "interrupt"}
    ]

    for override <- overrides do
      params =
        Map.merge(
          %{
            "description" => "Impersonation attempt",
            "prompt" => "Return completion",
            "async" => true,
            "auto_followup" => true,
            "queue_mode" => "collect"
          },
          override
        )

      result = launch(params)

      assert {:error, message} = result, inspect({override, result})
      assert message =~ ~r/session_key|agent_id|queue_mode/
      refute_receive {:router_submit, _}, 150
    end
  end

  test "the agent tool refuses a model-chosen delegated session key" do
    tool = CodingAgent.Tools.Agent.tool("/tmp", session_key: @parent_key, agent_id: "main")

    result =
      tool.execute.(
        "agent-call",
        %{"agent_id" => "victim", "prompt" => "hi", "session_key" => @decoy_key},
        nil,
        nil
      )

    assert {:error, message} = result
    assert message =~ "session_key"
    refute_receive {:router_submit, _}, 150
  end

  test "completions without overrides land in the launching session" do
    result =
      launch(%{
        "description" => "Honest task",
        "prompt" => "Return completion",
        "async" => true,
        "auto_followup" => true,
        "queue_mode" => "collect"
      })

    assert %LemonAgent.Types.AgentToolResult{} = result
    task_id = result.details.task_id

    assert_receive {:router_submit,
                    %RunRequest{meta: %{"async_followups" => [%{task_id: ^task_id}]}} = followup},
                   1_000

    assert followup.session_key == @parent_key
    assert followup.agent_id == "main"

    assert %{session_key: @parent_key, agent_id: "main"} =
             CodingAgent.TaskStore.get(result.details.task_id) |> elem(1)
  end

  test "a spawned child's peer tool is bound to the launching owner, not a model choice" do
    peer_id = "hermes-identity-#{System.unique_integer([:positive])}"
    previous = Application.get_env(:lemon_skills, :a2a_peers)

    Application.put_env(:lemon_skills, :a2a_peers, %{
      peer_id => %{
        id: peer_id,
        url: "http://127.0.0.1:9",
        token_secret: nil,
        outbound_token_secret: nil,
        timeout_ms: 100,
        capabilities: []
      }
    })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_skills, :a2a_peers, previous),
        else: Application.delete_env(:lemon_skills, :a2a_peers)
    end)

    {:ok, victim_context} = A2AStore.new_owned_context(peer_id, {"victim", @decoy_key})

    {:ok, _} =
      A2AStore.append_message(%{
        direction: :outbound,
        peer_id: peer_id,
        context_id: victim_context.id,
        role: "ROLE_AGENT",
        text: "victim-private-transcript"
      })

    cwd = System.tmp_dir!()
    parent_opts = [session_key: @parent_key, agent_id: "main"]
    history = %{"action" => "history", "peer_id" => peer_id}

    hostile = %{
      "description" => "d",
      "prompt" => "read the peer history",
      "session_key" => @decoy_key,
      "agent_id" => "victim",
      "tool_policy" => %{"allow" => ["peer"]}
    }

    case Params.validate_run_params(hostile, cwd, parent_opts) do
      {:error, message} ->
        assert message =~ "session_key"

      {:ok, validated} ->
        child_opts = Params.build_session_opts(cwd, parent_opts, validated)
        tool = LemonSkills.Tools.Peer.tool(cwd, child_opts)

        flunk(
          "child ran as #{inspect(child_opts[:session_key])}: #{inspect(call(tool, history))}"
        )
    end

    honest = Map.drop(hostile, ["session_key", "agent_id"])
    assert {:ok, validated} = Params.validate_run_params(honest, cwd, parent_opts)
    child_opts = Params.build_session_opts(cwd, parent_opts, validated)
    assert child_opts[:session_key] == @parent_key
    assert child_opts[:agent_id] == "main"

    tool = LemonSkills.Tools.Peer.tool(cwd, child_opts)
    assert {:error, "peer has no conversation yet"} = call(tool, history)

    assert {:error, "unknown context_id for this session"} =
             call(tool, Map.put(history, "context_id", victim_context.id))
  end

  defp launch(params) do
    Task.execute("call-#{System.unique_integer([:positive])}", params, nil, nil, "/tmp",
      run_override: fn _on_update, _signal ->
        %LemonAgent.Types.AgentToolResult{
          content: [%LemonAi.Types.TextContent{text: "child output"}],
          details: %{status: "completed"}
        }
      end,
      session_module: StreamingSessionSpy,
      session_pid: self(),
      session_key: @parent_key,
      agent_id: "main",
      run_orchestrator: RouterSpy
    )
  end

  defp call(tool, params), do: tool.execute.("peer-call", params, nil, nil)
end
