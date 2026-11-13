defmodule CodingAgent.Tools.Task.HubTest do
  use ExUnit.Case, async: false

  import CodingAgent.AsyncHelpers

  alias CodingAgent.{RunGraph, TaskStore}
  alias CodingAgent.Tools.Task.{Async, Control, Hub, Runner}
  alias LemonAgent.{AbortSignal, Test.Mocks}
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  defmodule Parent do
    def handle_async_followup(pid, message) do
      send(pid, {:child_reply, message})
      :ok
    end
  end

  @key "agent:default:tui:local:dm:hub-test"

  describe "membership" do
    setup do
      root = "root-#{System.unique_integer([:positive])}"
      opts = [session_id: root, session_key: @key, agent_id: "default"]

      direct =
        record(%{
          owner: Control.owner(opts),
          session_key: @key,
          parent_session_id: root,
          session_id: "#{root}-child",
          name: "Researcher",
          role: "scout",
          description: "Map the\nparser",
          status: :completed,
          agent_state: :parked,
          result: %AgentToolResult{
            content: [%TextContent{text: "Parser mapped"}],
            details: %{request_count: 4}
          }
        })

      nested =
        record(%{
          owner: {"#{root}-child", "default"},
          session_key: @key,
          parent_session_id: "#{root}-child",
          description: "Nested check",
          status: :running
        })

      foreign =
        record(%{
          owner: {"elsewhere", "default"},
          session_key: @key,
          parent_session_id: "elsewhere",
          description: "Another root session's child",
          status: :running
        })

      other_key =
        record(%{
          owner: Control.owner(opts),
          session_key: "agent:default:tui:local:dm:other",
          parent_session_id: root,
          description: "Same native parent, other routing key",
          status: :running
        })

      delegation =
        record(%{
          kind: :agent,
          session_key: @key,
          parent_session_id: root,
          description: "Router delegation, not a native task child",
          status: :running
        })

      %{
        root: root,
        direct: direct,
        nested: nested,
        foreign: foreign,
        other_key: other_key,
        delegation: delegation
      }
    end

    test "lists only the root's lineage, nested children with their parent", ctx do
      assert {:ok, agents} = Hub.list(@key, [ctx.root])
      by_id = Map.new(agents, &{&1.task_id, &1})
      assert Map.keys(by_id) |> Enum.sort() == Enum.sort([ctx.direct, ctx.nested])

      direct = by_id[ctx.direct]
      assert direct.depth == 0
      assert direct.parent_task_id == nil
      assert direct.name == "Researcher"
      assert direct.agent == "scout"
      assert direct.description == "Map the parser"
      assert direct.usage == %{requests: 4}
      # A persisted idle/parked child without a live control entry cannot be woken.
      assert direct.status == "completed"
      refute direct.messaging

      nested = by_id[ctx.nested]
      assert nested.depth == 1
      assert nested.parent_task_id == ctx.direct

      refute Enum.any?(agents, &Map.has_key?(&1, :prompt))
      assert {:ok, []} = Hub.list(@key, [])
      assert {:ok, []} = Hub.list(@key, ["unrelated-root"])
    end

    test "foreign, cross-key and delegation IDs are not found for every operation", ctx do
      for id <- [ctx.foreign, ctx.other_key, ctx.delegation, "missing", nil] do
        assert {:error, :not_found} = Hub.transcript(@key, [ctx.root], id)
        assert {:error, :not_found} = Hub.send(@key, [ctx.root], id, "hello")
        assert {:error, :not_found} = Hub.cancel(@key, [ctx.root], id)
      end

      assert {:error, :not_found} = Hub.transcript("agent:default:main", [ctx.root], ctx.direct)
    end

    test "transcript is the bounded history projection", ctx do
      assert {:ok, %{task_id: id, status: "completed", text: text, truncated: false}} =
               Hub.transcript(@key, [ctx.root], ctx.direct)

      assert id == ctx.direct
      assert text =~ "Parser mapped"
      assert text =~ "Assignment: Map the\nparser"
    end

    test "terminal or untracked children refuse messages and cancellation", ctx do
      assert {:error, :not_running} = Hub.send(@key, [ctx.root], ctx.direct, "wake up")
      assert {:error, :not_running} = Hub.cancel(@key, [ctx.root], ctx.direct)
      # Running in the store, but no live control entry: the runtime restarted.
      assert {:error, :not_resumable} = Hub.send(@key, [ctx.root], ctx.nested, "status?")
    end

    test "the runtime provider scopes by the key's resumed native session", ctx do
      key = "agent:default:tui:local:dm:hub-provider-#{System.unique_integer([:positive])}"
      :ok = LemonCore.ChatStateStore.put(key, %LemonCore.ChatState{last_resume_token: ctx.root})
      on_exit(fn -> LemonCore.ChatStateStore.delete(key) end)

      child =
        record(%{
          owner: {ctx.root, "default"},
          session_key: key,
          parent_session_id: ctx.root,
          description: "Provider-scoped child",
          status: :queued
        })

      assert {:ok, [%{task_id: ^child, status: "queued"}]} =
               CodingAgent.ControlPlaneProvider.subagents_list(key)

      assert {:ok, %{task_id: ^child}} =
               CodingAgent.ControlPlaneProvider.subagent_transcript(key, child)

      assert {:error, :not_found} =
               CodingAgent.ControlPlaneProvider.subagent_transcript(key, ctx.direct)

      assert {:ok, []} = CodingAgent.ControlPlaneProvider.subagents_list("agent:default:unknown")
    end
  end

  describe "live children" do
    @tag :tmp_dir
    test "wakes an idle child, reports live usage and cancels terminally", %{tmp_dir: cwd} do
      child = launch(cwd)

      assert {:ok, [agent]} = Hub.list(@key, [child.root])
      assert agent.task_id == child.id
      assert agent.status == "idle"
      assert agent.messaging and agent.cancellable
      assert is_binary(agent.model)
      assert agent.usage.requests >= 1

      assert {:ok, :woken} = Hub.send(@key, [child.root], child.id, "Operator follow-up")
      assert_receive {:model_call, 2, _model, context}, 5_000
      assert inspect(context.messages) =~ "Operator follow-up"
      refute inspect(context.messages) =~ "Peer-agent content"
      assert_receive {:child_reply, reply}, 5_000
      assert inspect(reply.content) =~ "answer-2"

      assert_eventually(fn -> hub_status(child) == "idle" end, timeout: 5_000)
      assert :ok = Hub.cancel(@key, [child.root], child.id)
      assert_eventually(fn -> hub_status(child) == "cancelled" end, timeout: 5_000)
      assert {:error, :not_running} = Hub.send(@key, [child.root], child.id, "again")
      assert {:error, :not_running} = Hub.cancel(@key, [child.root], child.id)

      assert {:ok, %{status: "cancelled", text: text}} =
               Hub.transcript(@key, [child.root], child.id)

      assert text =~ "answer-2"
    end
  end

  defp hub_status(child) do
    {:ok, [agent]} = Hub.list(@key, [child.root])
    agent.status
  end

  defp record(attrs) do
    id = TaskStore.new_task(attrs)
    on_exit(fn -> TaskStore.delete_task(id) end)
    id
  end

  defp launch(cwd) do
    owner = self()
    root = "root-#{System.unique_integer([:positive])}"
    count = :atomics.new(1, [])
    opts = [parent_session: root, session_key: @key, agent_id: "default", session_pid: owner]
    run_id = RunGraph.new_run(%{type: :task, description: "Hub child"})

    id =
      TaskStore.new_task(%{
        owner: Control.owner(opts),
        session_key: @key,
        parent_session_id: root,
        name: "Worker",
        description: "Hub child",
        prompt: "original assignment",
        run_id: run_id
      })

    signal = AbortSignal.new()

    stream_fn = fn model, context, stream_options ->
      n = :atomics.add_get(count, 1, 1)
      send(owner, {:model_call, n, model, context})

      Mocks.mock_stream_fn_single(Mocks.assistant_message("answer-#{n}")).(
        model,
        context,
        stream_options
      )
    end

    lifecycle = %{
      signal: signal,
      description: "Hub child",
      parent_session_pid: owner,
      run_id: run_id
    }

    followup = %{
      auto_followup: false,
      session_pid: owner,
      session_module: Parent,
      queue_mode: :followup
    }

    start_opts = [
      cwd: cwd,
      workspace_dir: cwd,
      register: true,
      tools: [],
      model: Mocks.mock_model(),
      stream_fn: stream_fn
    ]

    assert :ok =
             Async.run_async(
               id,
               run_id,
               fn ->
                 Runner.start_session_with_prompt(
                   start_opts,
                   "original assignment",
                   "Hub child",
                   signal,
                   nil,
                   nil,
                   task_id: id,
                   idle_ttl_ms: 0,
                   task_session_poll_ms: 10
                 )
               end,
               followup,
               lifecycle
             )

    assert_receive {:model_call, 1, _, _}, 5_000

    assert_eventually(
      fn ->
        {:ok, record} = TaskStore.get_record(id)
        record[:agent_state] == :idle
      end,
      timeout: 5_000
    )

    on_exit(fn ->
      Control.command(id, "cancel", nil, opts)
      Control.complete(id)
      TaskStore.delete_task(id)
    end)

    %{id: id, root: root}
  end
end
