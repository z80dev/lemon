defmodule CodingAgent.Tools.TaskPersonasTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{RunGraph, TaskStore, ToolPolicy}
  alias CodingAgent.Tools.Task, as: TaskTool
  alias CodingAgent.Tools.Task.Params
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @schema %{
    "type" => "object",
    "required" => ["answer"],
    "properties" => %{"answer" => %{"type" => "integer"}},
    "additionalProperties" => false
  }

  @tag :tmp_dir
  test "native scout receives a system persona and cannot gain writing tools", %{tmp_dir: cwd} do
    owner = self()
    response = Mocks.mock_stream_fn_single(Mocks.assistant_message(~s({"answer":42})))

    opts = [
      parent_session: unique_id(),
      model: "openai-codex:gpt-6.1-sol",
      system_prompt: "Parent custom instruction.",
      stream_fn: fn model, context, options ->
        send(owner, {:child_context, context})
        response.(model, context, options)
      end
    ]

    result =
      execute(cwd, opts, %{
        "prompt" => "Inspect the project.",
        "agent" => "scout",
        "tool_policy" => %{"allow" => "all"},
        "output_schema" => @schema,
        "async" => false,
        "auto_followup" => false
      })

    assert result.details.status == "completed"
    assert result.details.structured_output == %{"answer" => 42}
    assert_receive {:child_context, context}, 2_000
    assert context.system_prompt =~ "Parent custom instruction."
    assert context.system_prompt =~ CodingAgent.Subagents.get(cwd, "scout").prompt
    assert context.system_prompt =~ "ONLY valid JSON"
    names = Enum.map(context.tools, & &1.name)
    assert "read" in names
    assert "agent_message" in names
    assert Enum.all?(names, &(&1 in ~w(read grep find ls agent_message)))

    assert {:ok, record, _events} = TaskStore.get(result.details.task_id)
    assert record.result.details.structured_output == %{"answer" => 42}
  end

  @tag :tmp_dir
  test "project persona defaults are lower priority than explicit selectors", %{tmp_dir: cwd} do
    path = Path.join(cwd, ".lemon/agents")
    File.mkdir_p!(path)

    File.write!(Path.join(path, "architect.md"), """
    ---
    description: Architecture review
    role: coding
    tools: [read, grep]
    ---
    Explain dependency boundaries.
    """)

    assert {:ok, persona} =
             Params.validate_run_params(%{"prompt" => "Inspect", "agent" => "architect"}, cwd)

    assert persona.model == "@coding"
    refute persona.model_explicit
    assert persona.persona.prompt == "Explain dependency boundaries."
    assert ToolPolicy.allowed?(persona.tool_policy, "read")
    refute ToolPolicy.allowed?(persona.tool_policy, "write")
    refute ToolPolicy.allowed?(persona.tool_policy, "bash")

    assert {:ok, explicit} =
             Params.validate_run_params(
               %{"prompt" => "Inspect", "agent" => "architect", "model" => "@review"},
               cwd
             )

    assert explicit.model == "@review"
    assert explicit.model_explicit

    settings = %CodingAgent.SettingsManager{
      model_roles: %{
        "task" => "openai:gpt-4",
        "coding" => "openai:gpt-4o-mini",
        "review" => "openai:gpt-4o"
      }
    }

    assert Params.build_session_opts(cwd, [settings_manager: settings], persona)[:model].id ==
             "gpt-4o-mini"

    assert Params.build_session_opts(cwd, [settings_manager: settings], explicit)[:model].id ==
             "gpt-4o"

    refute Params.build_session_opts(cwd, [settings_manager: settings], persona)[:model_explicit]
    assert Params.build_session_opts(cwd, [settings_manager: settings], explicit)[:model_explicit]

    assert {:error, _} =
             Params.validate_run_params(%{"prompt" => "Inspect", "role" => "architect"}, cwd)
  end

  test "schema output is validated before completion and preserved through get and join" do
    opts = [parent_session: unique_id(), run_override: fn _, _ -> result(~s({"answer":42})) end]

    receipt =
      execute("/tmp", opts, %{
        "prompt" => "Compute",
        "output_schema" => @schema,
        "auto_followup" => false
      })

    joined = execute("/tmp", opts, %{"action" => "join", "task_ids" => [receipt.details.task_id]})
    assert [%{status: "completed", structured_output: %{"answer" => 42}}] = joined.details.tasks
    fetched = execute("/tmp", opts, %{"action" => "get", "task_id" => receipt.details.task_id})
    assert fetched.details.structured_output == %{"answer" => 42}

    bad_opts = [
      parent_session: unique_id(),
      run_override: fn _, _ -> result(~s({"answer":"wrong"})) end
    ]

    bad =
      execute("/tmp", bad_opts, %{
        "prompt" => "Compute",
        "output_schema" => @schema,
        "auto_followup" => false
      })

    joined_bad =
      execute("/tmp", bad_opts, %{"action" => "join", "task_ids" => [bad.details.task_id]})

    assert [failed] = joined_bad.details.tasks
    assert failed.status == "error"
    assert failed.error =~ "type mismatch"
    refute Map.has_key?(failed, :structured_output)
  end

  test "JSON null remains a present structured output field" do
    opts = [parent_session: unique_id(), run_override: fn _, _ -> result("null") end]

    receipt =
      execute("/tmp", opts, %{
        "prompt" => "Return null",
        "output_schema" => %{"type" => "null"},
        "auto_followup" => false
      })

    joined = execute("/tmp", opts, %{"action" => "join", "task_ids" => [receipt.details.task_id]})
    assert [%{status: "completed", structured_output: nil}] = joined.details.tasks
  end

  test "native task descendants inherit their own run ID, not the parent's" do
    parent = RunGraph.new_run(%{type: :session})

    opts = [
      parent_session: unique_id(),
      run_id: parent,
      run_override: fn _, _ -> result("Done") end
    ]

    child =
      execute("/tmp", opts, %{"prompt" => "Work", "auto_followup" => false})

    assert child.details.parent_run_id == parent
    assert child.details.parent_session_id == opts[:parent_session]
    execute("/tmp", opts, %{"action" => "join", "task_ids" => [child.details.task_id]})
    assert {:ok, run} = RunGraph.get(child.details.run_id)
    assert run.parent == parent
    assert {:ok, parent_record} = RunGraph.get(parent)
    assert child.details.run_id in parent_record.children

    assert {:ok, validated} = Params.validate_run_params(%{"prompt" => "Work"}, "/tmp")

    child_opts =
      Params.build_session_opts(
        "/tmp",
        [run_id: parent, child_run_id: child.details.run_id],
        validated
      )

    assert child_opts[:run_id] == child.details.run_id
    assert child_opts[:session_scope] == :subagent
  end

  @tag :tmp_dir
  test "nested native progress reaches the root without changing descendant identity", %{
    tmp_dir: cwd
  } do
    owner = self()

    stream_fn = fn model, context, options ->
      coordinator? = Enum.any?(context.tools, &(&1.name == "task"))
      answered? = Enum.any?(context.messages, &(Map.get(&1, :role) == :tool_result))

      response =
        if coordinator? and not answered? do
          Mocks.assistant_message_with_tool_calls([
            Mocks.tool_call("task", %{
              "tasks" => [
                %{"agent" => "scout", "prompt" => "Inspect the project"},
                %{"agent" => "reviewer", "prompt" => "Review the project"}
              ],
              "async" => false,
              "auto_followup" => false
            })
          ])
        else
          Mocks.assistant_message("Read-only inspection complete.")
        end

      Mocks.mock_stream_fn_single(response).(model, context, options)
    end

    outer =
      TaskTool.execute(
        unique_id(),
        %{
          "prompt" => "Coordinate the inspection",
          "agent" => "task-executor",
          "tool_policy" => %{"allow" => "all"},
          "async" => false,
          "auto_followup" => false
        },
        nil,
        fn update -> send(owner, {:tree_progress, update.details}) end,
        cwd,
        parent_session: unique_id(),
        model: "openai-codex:gpt-6.1-sol",
        stream_fn: stream_fn
      )

    assert outer.details.status == "completed"
    outer_run = outer.details.run_id

    for persona <- ["scout", "reviewer"] do
      assert_receive {:tree_progress,
                      %{parent_run_id: ^outer_run, agent: ^persona, status: "completed"} =
                        progress},
                     2_000

      assert progress.task_id != outer.details.task_id
      assert progress.session_id != outer.details.session_id
      assert progress.parent_session_id == outer.details.session_id
      assert {:ok, child} = RunGraph.get(progress.run_id)
      assert child.parent == outer_run
    end
  end

  defp execute(cwd, opts, params), do: TaskTool.execute(unique_id(), params, nil, nil, cwd, opts)
  defp result(text), do: %AgentToolResult{content: [%TextContent{text: text}], details: %{}}
  defp unique_id, do: "persona-#{System.unique_integer([:positive, :monotonic])}"
end
