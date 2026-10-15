defmodule CodingAgent.Tools.ContextCheckpointTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.ContextCheckpoint
  alias CodingAgent.SessionManager
  alias CodingAgent.Tools.{Checkpoint, Rewind}
  alias LemonAi.Types.{AssistantMessage, TextContent, ToolCall, ToolResultMessage, UserMessage}

  @moduletag :tmp_dir

  test "pair is disabled by default, opt-in and explicitly requested in subagents", %{
    tmp_dir: cwd
  } do
    opts = [settings_manager: %{tools: %{checkpoint: %{enabled: false}}}, session_pid: self()]
    refute Checkpoint.available?(opts)
    enabled = Keyword.put(opts, :settings_manager, %{tools: %{checkpoint: %{enabled: true}}})
    assert Checkpoint.available?(enabled)
    refute Checkpoint.available?(Keyword.delete(enabled, :session_pid))
    refute Checkpoint.available?(Keyword.put(enabled, :session_scope, :subagent))
    assert Checkpoint.available?(enabled ++ [session_scope: :subagent, enabled_only: ["rewind"]])

    names =
      CodingAgent.ToolRegistry.get_tools(
        cwd,
        enabled ++ [enabled_only: ["rewind"], include_extensions: false, include_mcp: false]
      )
      |> Enum.map(& &1.name)

    assert Enum.sort(names) == ["checkpoint", "rewind"]
    assert Checkpoint.tool(cwd).parameters["required"] == ["goal"]
    assert Rewind.tool(cwd).parameters["required"] == ["report"]
    assert CodingAgent.Tools.FsCheckpoint.tool(cwd).name == "fs_checkpoint"
  end

  test "native session's next provider call and durable branch both drop exploration", %{
    tmp_dir: cwd
  } do
    parent = self()
    counter = :counters.new(1, [])

    model = %LemonAi.Types.Model{
      id: "checkpoint-test",
      name: "Checkpoint test",
      api: :mock,
      provider: :mock,
      base_url: "http://unused.invalid",
      reasoning: false,
      input: [:text],
      cost: %LemonAi.Types.ModelCost{},
      context_window: 128_000,
      max_tokens: 4096
    }

    stream = fn _model, context, _options ->
      turn = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      send(parent, {:provider_context, turn, context.messages})

      content =
        case turn do
          0 ->
            [%ToolCall{id: "cp", name: "checkpoint", arguments: %{"goal" => "trace"}}]

          1 ->
            [
              %TextContent{text: "throwaway exploration"},
              %ToolCall{
                id: "read",
                name: "read",
                arguments: %{"path" => Path.join(cwd, "notes.txt")}
              }
            ]

          2 ->
            [%ToolCall{id: "rw", name: "rewind", arguments: %{"report" => "retained finding"}}]

          _ ->
            [%TextContent{text: "finished"}]
        end

      response = %AssistantMessage{
        content: content,
        api: :mock,
        provider: :mock,
        model: model.id,
        usage: %LemonAi.Types.Usage{},
        stop_reason: if(turn < 3, do: :tool_use, else: :stop)
      }

      {:ok, events} = LemonAi.EventStream.start_link()

      Task.start(fn ->
        LemonAi.EventStream.push(events, {:start, response})
        LemonAi.EventStream.push(events, {:done, response.stop_reason, response})
        LemonAi.EventStream.complete(events, response)
      end)

      {:ok, events}
    end

    File.write!(Path.join(cwd, "notes.txt"), "discarded raw notes")
    SessionManager.new(cwd) |> SessionManager.persist(Path.join(cwd, "native.jsonl"))

    settings = %CodingAgent.SettingsManager{
      tools: %{checkpoint: %{enabled: true}},
      extension_paths: []
    }

    {:ok, session} =
      CodingAgent.Session.start_link(
        cwd: cwd,
        workspace_dir: Path.join(cwd, "workspace"),
        session_file: Path.join(cwd, "native.jsonl"),
        settings_manager: settings,
        model: model,
        stream_fn: stream,
        get_api_key: fn _ -> nil end,
        system_prompt: "Test",
        include_extensions: false,
        include_mcp: false,
        enabled_only: ["checkpoint", "read"],
        context_guardrails: %{enabled: false}
      )

    Process.unlink(session)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)
    CodingAgent.Session.subscribe(session)
    assert :ok = CodingAgent.Session.prompt(session, "investigate")
    assert_receive {:provider_context, 3, messages}, 5_000
    text = inspect(messages)
    assert text =~ "retained finding"
    refute text =~ "throwaway exploration"
    refute text =~ "discarded raw notes"
    await_end()
    state = CodingAgent.Session.get_state(session)
    branch = SessionManager.get_branch(state.session_manager)
    assert Enum.any?(branch, &(&1.type == :branch_summary and &1.summary =~ "retained finding"))
    refute inspect(Enum.map(branch, & &1.message)) =~ "throwaway exploration"
  end

  test "tools use the session port and return authenticated receipts", %{tmp_dir: cwd} do
    {:ok, port} = Agent.start_link(fn -> SessionManager.new(cwd) end)
    session = spawn(fn -> serve(port) end)
    on_exit(fn -> Process.exit(session, :kill) end)
    tool = Checkpoint.tool(cwd, session_pid: session)

    assert %{details: %{context_checkpoint: true, goal: "trace"}} =
             tool.execute.("cp", %{"goal" => "trace"}, nil, nil)

    assert {:error, "Checkpoint already active."} =
             tool.execute.("cp2", %{"goal" => "nested"}, nil, nil)

    rewind = Rewind.tool(cwd, session_pid: session)

    assert {:error, "Checkpoint is not ready" <> _} =
             rewind.execute.("rw", %{"report" => "findings"}, nil, nil)

    assert {:error, "Expected a string."} = rewind.execute.("rw", %{}, nil, nil)
  end

  test "retains findings and sibling work, never restores files, persists single-use branch state",
       %{tmp_dir: cwd} do
    path = Path.join(cwd, "file.txt")
    File.write!(path, "before")
    session = SessionManager.new(cwd) |> SessionManager.persist(Path.join(cwd, "session.jsonl"))
    initial = %UserMessage{content: "investigate"}
    session = SessionManager.append_message(session, initial)

    assert {:error, "No active checkpoint" <> _} =
             ContextCheckpoint.request(session, "rewind", "rw", "report")

    {session, cp_assistant, cp_result} = checkpoint(session)

    assert {:error, "Checkpoint already active."} =
             ContextCheckpoint.request(session, "checkpoint", "other", "nested")

    assert {:error, "Report cannot be empty."} =
             ContextCheckpoint.request(session, "rewind", "rw", "  ")

    {:ok, resumed} = SessionManager.load_from_file(session.file_path)
    resumed = SessionManager.persist(resumed, session.file_path)
    assert ContextCheckpoint.active(resumed).data.status == "active"

    exploration = %AssistantMessage{content: [%TextContent{text: "discard this exploration"}]}
    session = SessionManager.append_message(resumed, exploration)
    File.write!(path, "changed by exploration")

    {:ok, receipt, session} =
      ContextCheckpoint.request(session, "rewind", "rw", "  useful findings  ")

    assert receipt.report == "useful findings"

    assert {:error, "Checkpoint already completed" <> _} =
             ContextCheckpoint.request(session, "rewind", "rw2", "again")

    assistant = %AssistantMessage{
      content: [
        %ToolCall{id: "rw", name: "rewind", arguments: %{"report" => "useful findings"}},
        %ToolCall{id: "sibling", name: "read", arguments: %{"path" => "file.txt"}}
      ]
    }

    rewind = result("rw", "rewind", receipt)
    sibling = result("sibling", "read", %{kept: true})

    full =
      Enum.reduce([assistant, rewind, sibling], session, &SessionManager.append_message(&2, &1))

    {rewound, true} = ContextCheckpoint.complete_turn(full, assistant, [rewind, sibling])
    assert ContextCheckpoint.active(rewound) == nil
    assert File.read!(path) == "changed by exploration"
    assert Enum.any?(SessionManager.entries(rewound), &(&1.message == exploration))
    branch = SessionManager.get_branch(rewound)
    refute Enum.any?(branch, &(&1.message == exploration or &1.message == rewind))
    assert Enum.any?(branch, &(&1.type == :branch_summary and &1.summary =~ "useful findings"))
    assert List.last(branch).message == sibling
    assert List.last(branch).parent_id == Enum.at(branch, -2).id

    projected =
      ContextCheckpoint.project([
        initial,
        cp_assistant,
        cp_result,
        exploration,
        assistant,
        rewind,
        sibling
      ])

    refute exploration in projected
    refute rewind in projected
    assert sibling in projected

    retained =
      Enum.find(projected, &match?(%AssistantMessage{content: [%ToolCall{id: "sibling"}]}, &1))

    assert retained
    assert Enum.any?(projected, &match?(%CodingAgent.Messages.BranchSummaryMessage{}, &1))
    {:ok, completed} = SessionManager.load_from_file(full.file_path)
    assert ContextCheckpoint.active(completed) == nil

    assert {:error, "No active checkpoint" <> _} =
             ContextCheckpoint.request(completed, "rewind", "rw3", "again")

    assert {:ok, _, _} =
             ContextCheckpoint.request(completed, "checkpoint", "new", "next exploration")
  end

  test "rewind cannot remove later user direction and failed results do not consume checkpoint",
       %{tmp_dir: cwd} do
    {session, _, _} = checkpoint(SessionManager.new(cwd))
    later = SessionManager.append_message(session, %UserMessage{content: "new direction"})

    assert {:error, "Cannot rewind across a new user message."} =
             ContextCheckpoint.request(later, "rewind", "rw", "findings")

    {:ok, _, pending} = ContextCheckpoint.request(session, "rewind", "rw", "findings")
    failed = %{result("rw", "rewind", %{}) | is_error: true}
    {restored, false} = ContextCheckpoint.complete_turn(pending, nil, [failed])
    assert ContextCheckpoint.active(restored).data.status == "active"
    assert {:ok, _, _} = ContextCheckpoint.request(restored, "rewind", "retry", "findings")
  end

  defp checkpoint(session) do
    {:ok, receipt, session} = ContextCheckpoint.request(session, "checkpoint", "cp", "trace")

    assistant = %AssistantMessage{
      content: [%ToolCall{id: "cp", name: "checkpoint", arguments: %{"goal" => "trace"}}]
    }

    result = result("cp", "checkpoint", receipt)

    session =
      session |> SessionManager.append_message(assistant) |> SessionManager.append_message(result)

    {session, false} = ContextCheckpoint.complete_turn(session, assistant, [result])
    {session, assistant, result}
  end

  defp result(id, name, details),
    do: %ToolResultMessage{
      tool_call_id: id,
      tool_name: name,
      content: [%TextContent{text: "ok"}],
      details: details
    }

  defp await_end do
    receive do
      {:session_event, _, {:agent_end, _}} -> :ok
      _ -> await_end()
    after
      5_000 -> flunk("session did not finish")
    end
  end

  defp serve(agent) do
    receive do
      {:"$gen_call", from, {:context_checkpoint, operation, id, value}} ->
        reply =
          Agent.get_and_update(agent, fn session ->
            case ContextCheckpoint.request(session, operation, id, value) do
              {:ok, details, updated} -> {{:ok, details}, updated}
              error -> {error, session}
            end
          end)

        GenServer.reply(from, reply)
        serve(agent)
    end
  end
end
