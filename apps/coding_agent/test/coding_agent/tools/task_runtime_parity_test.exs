defmodule CodingAgent.Tools.TaskRuntimeParityTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{SettingsManager, ToolPolicy}
  alias CodingAgent.Tools.Task, as: TaskTool
  alias CodingAgent.Tools.Task.{Messaging, Params}
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @model "openai-codex:gpt-6.1-sol"

  @schema %{
    "type" => "object",
    "required" => ["answer"],
    "properties" => %{"answer" => %{"type" => "integer"}},
    "additionalProperties" => false
  }

  describe "shared context" do
    test "wraps every batch child's assignment in a delimited block" do
      owner = self()

      opts =
        base_opts(
          run_override: fn _update, _signal, context ->
            send(owner, {:child_prompt, context.description, context.prompt})
            result("done")
          end
        )

      joined =
        execute("/tmp", opts, %{
          "context" => "  The repo is an Elixir umbrella.  ",
          "tasks" => [
            %{"description" => "one", "prompt" => "Inspect lib"},
            %{"description" => "two", "prompt" => "Inspect test"}
          ],
          "async" => false
        })

      assert Enum.all?(joined.details.tasks, &(&1.status == "completed"))
      assert_receive {:child_prompt, "one", first}
      assert_receive {:child_prompt, "two", second}

      assert first ==
               "<context>\nThe repo is an Elixir umbrella.\n</context>\n\n" <>
                 "<assignment>\nInspect lib\n</assignment>"

      assert second =~ "<assignment>\nInspect test\n</assignment>"
    end

    test "is top-level only and bounded" do
      opts = base_opts(run_override: fn _, _ -> result("done") end)

      assert {:error, "context is only supported at the top level, not per task"} =
               execute("/tmp", opts, %{"tasks" => [%{"prompt" => "x", "context" => "per item"}]})

      assert {:error, "swarm task 1: context is only supported at the top level, not per task"} =
               execute("/tmp", opts, %{
                 "action" => "swarm",
                 "tasks" => [%{"name" => "A", "prompt" => "x", "context" => "per item"}]
               })

      for context <- ["   ", 42, String.duplicate("a", 64 * 1024 + 1)] do
        assert {:error, "context must be a non-empty string of at most 64 KiB"} =
                 Params.validate_run_params(%{"prompt" => "x", "context" => context}, "/tmp",
                   settings_manager: settings()
                 )
      end
    end

    test "tool-only guardrails are inferred from the assignment, not the context" do
      assert {:ok, from_context} =
               Params.validate_run_params(
                 %{"prompt" => "Summarize", "context" => "Use bash tools only"},
                 "/tmp",
                 settings_manager: settings()
               )

      assert from_context.tool_policy.profile == :leaf_worker
      refute from_context.prompt =~ "Tool execution requirement"

      assert {:ok, from_prompt} =
               Params.validate_run_params(
                 %{"prompt" => "Use read tools only", "context" => "Background"},
                 "/tmp",
                 settings_manager: settings()
               )

      assert from_prompt.tool_policy.allow == ["read"]
      assert from_prompt.prompt =~ "<assignment>\nTool execution requirement"
    end
  end

  describe "per-item batch execution" do
    test "mixes sync and async children without joining background siblings" do
      owner = self()

      opts =
        base_opts(
          run_override: fn _, _, context ->
            send(owner, {:started, context.description, self()})

            if context.description == "background" do
              receive do
                :finish -> result("background answer")
              after
                5_000 -> {:error, "test worker not released"}
              end
            else
              result("sync answer")
            end
          end
        )

      joined =
        execute("/tmp", opts, %{
          "async" => false,
          "thinking_level" => "medium",
          "tasks" => [
            %{
              "description" => "background",
              "prompt" => "wait",
              "async" => true,
              "thinking_level" => "low"
            },
            %{
              "description" => "foreground",
              "prompt" => "answer",
              "async" => false,
              "thinking_level" => "high"
            }
          ]
        })

      assert_receive {:started, "background", worker}
      assert_receive {:started, "foreground", _}

      try do
        assert [%{output: "sync answer"}] = joined.details.tasks
        assert [%{async: true, task_id: async_id}, %{async: false}] = joined.details.launches
        assert Enum.any?(joined.content, &(&1.text =~ async_id))
        assert {:ok, %{status: :running}, _} = CodingAgent.TaskStore.get(async_id)
      after
        send(worker, :finish)
      end

      execute("/tmp", opts, %{"action" => "join", "task_ids" => joined.details.task_ids})
    end

    test "item async is present in schema and validated rather than overwritten" do
      tool = TaskTool.tool("/tmp", base_opts([]))
      item = tool.parameters["properties"]["tasks"]["items"]["properties"]
      assert item["async"]["type"] == "boolean"
      assert item["thinking_level"]["type"] == "string"

      for thinking <- ["low", "high"] do
        assert {:ok, %{thinking_level: ^thinking}} =
                 Params.validate_run_params(
                   %{"prompt" => "x", "thinking_level" => thinking},
                   "/tmp",
                   settings_manager: settings()
                 )
      end

      assert {:error, "Async must be a boolean"} =
               execute("/tmp", base_opts([]), %{
                 "tasks" => [%{"prompt" => "x", "async" => "invalid"}]
               })
    end
  end

  describe "persona and config defaults" do
    @tag :tmp_dir
    test "persona thinking level and output schema apply unless explicitly overridden", %{
      tmp_dir: cwd
    } do
      define(cwd, "planner", """
      description: Planner
      role: coding
      thinking: high
      output:
        type: object
        required: [answer]
        properties:
          answer:
            type: integer
        additionalProperties: false
      """)

      session_settings = %{settings() | model_roles: %{"coding" => "openai:gpt-4o-mini"}}

      assert {:ok, validated} =
               Params.validate_run_params(%{"prompt" => "Plan", "agent" => "planner"}, cwd,
                 settings_manager: session_settings
               )

      assert validated.thinking_level == "high"
      assert validated.output_schema == @schema
      assert validated.model == "@coding"

      assert {:ok, explicit} =
               Params.validate_run_params(
                 %{
                   "prompt" => "Plan",
                   "agent" => "planner",
                   "thinking_level" => "low",
                   "output_schema" => false,
                   "model" => "openai:gpt-4o"
                 },
                 cwd,
                 settings_manager: session_settings
               )

      assert explicit.thinking_level == "low"
      assert explicit.output_schema == false
      assert explicit.model == "openai:gpt-4o"
    end

    @tag :tmp_dir
    test "agent_models overrides persona models and disabled_agents hides personas", %{
      tmp_dir: cwd
    } do
      dir = Path.join(cwd, ".lemon/agents")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "architect.md"), """
      ---
      description: Architecture review
      role: coding
      ---
      Explain dependency boundaries.
      """)

      overridden = settings(%{agent_models: %{"architect" => "@review"}})

      assert {:ok, %{model: "@review"}} =
               Params.validate_run_params(%{"prompt" => "x", "agent" => "architect"}, cwd,
                 settings_manager: overridden
               )

      assert {:ok, %{model: "openai:gpt-4o"}} =
               Params.validate_run_params(
                 %{"prompt" => "x", "agent" => "architect", "model" => "openai:gpt-4o"},
                 cwd,
                 settings_manager: overridden
               )

      disabled = settings(%{disabled_agents: ["scout"]})
      enum = Params.build_agent_enum(cwd, settings_manager: disabled)
      refute "scout" in enum
      assert "architect" in enum

      tool = TaskTool.tool(cwd, settings_manager: disabled)
      refute tool.description =~ "- scout:"
      assert tool.description =~ "- architect:"
      refute "scout" in tool.parameters["properties"]["agent"]["enum"]

      assert {:error, "Subagent 'scout' is disabled by [runtime.task].disabled_agents"} =
               execute(cwd, base_opts(settings_manager: disabled), %{
                 "prompt" => "x",
                 "agent" => "scout"
               })
    end

    test "max_runtime_ms bounds a child session when no explicit timeout is set" do
      opts =
        base_opts(
          model: @model,
          settings_manager: settings(%{max_runtime_ms: 150}),
          stream_fn:
            Mocks.blocking_stream_fn(Mocks.assistant_message("late"), self(), max_block_ms: 2_000)
        )

      assert {:error, message} =
               execute("/tmp", opts, %{
                 "prompt" => "Wait",
                 "async" => false,
                 "auto_followup" => false
               })

      assert message =~ "timed out after 150ms"
    end
  end

  describe "nesting depth" do
    test "launches are refused when the session is at max_depth" do
      opts = base_opts(run_override: fn _, _ -> result("done") end)
      at_zero = Keyword.put(opts, :settings_manager, settings(%{max_depth: 0}))

      for params <- [
            %{"prompt" => "x"},
            %{"tasks" => [%{"prompt" => "x"}]},
            %{"action" => "swarm", "tasks" => [%{"name" => "A", "prompt" => "x"}]}
          ] do
        assert {:error, message} = execute("/tmp", at_zero, params)
        assert message =~ "Task nesting limit reached: this session is at depth 0"
      end

      assert {:error, message} =
               execute("/tmp", Keyword.put(opts, :task_depth, 2), %{"prompt" => "x"})

      assert message =~ "depth 2"

      assert {:error, message} =
               execute("/tmp", Keyword.put(opts, :session_scope, :subagent), %{"prompt" => "x"})

      assert message =~ "nesting depth is unknown"

      assert {:error, _} =
               execute("/tmp", Keyword.merge(opts, session_scope: :subagent, task_child: nil), %{
                 "prompt" => "x"
               })

      unlimited =
        opts
        |> Keyword.put(:settings_manager, settings(%{max_depth: -1}))
        |> Keyword.put(:task_depth, 10)

      assert %AgentToolResult{details: %{task_id: _}} =
               execute("/tmp", unlimited, %{"prompt" => "x", "auto_followup" => false})
    end

    test "a capped child session is built without the task tool" do
      owner = self()
      response = Mocks.mock_stream_fn_single(Mocks.assistant_message("done"))

      opts =
        base_opts(
          model: @model,
          settings_manager: settings(%{max_depth: 1}),
          stream_fn: fn model, context, options ->
            send(owner, {:child_tools, Enum.map(context.tools, & &1.name)})
            response.(model, context, options)
          end
        )

      result =
        execute("/tmp", opts, %{
          "prompt" => "Work",
          "tool_policy" => %{"allow" => "all"},
          "async" => false,
          "auto_followup" => false
        })

      assert result.details.status == "completed"
      assert_receive {:child_tools, names}, 2_000
      refute "task" in names
      assert "read" in names
    end
  end

  describe "persona spawns" do
    test "read-only identities and caller policies cannot be widened by spawns" do
      for read_only <- [
            persona(%{id: "scout", spawns: :all}),
            persona(%{id: "security-reviewer", spawns: :all}),
            persona(%{read_only: true, spawns: :all})
          ] do
        launch = Params.persona_launch(read_only, %{}, settings().task, 0)
        refute ToolPolicy.allowed?(launch.tool_policy, "task")
        assert launch.task_allowed_agents == nil
      end

      lead = persona(%{id: "lead", tools: ["read", "bash"], spawns: ["scout"]})

      restricted =
        Params.persona_launch(lead, %{tool_policy: %{"allow" => ["read"]}}, settings().task, 0)

      refute ToolPolicy.allowed?(restricted.tool_policy, "task")
    end

    @tag :tmp_dir
    test "a discovered spawns persona gets task in its child session with the allowlist", %{
      tmp_dir: cwd
    } do
      define(cwd, "lead", """
      description: Lead
      tools: [read, bash]
      spawns: [scout]
      """)

      assert {:ok, validated} =
               Params.validate_run_params(%{"prompt" => "Lead", "agent" => "lead"}, cwd,
                 settings_manager: settings()
               )

      assert ToolPolicy.allowed?(validated.tool_policy, "task")
      refute ToolPolicy.allowed?(validated.tool_policy, "write")
      assert validated.task_allowed_agents == ["scout"]

      owner = self()
      response = Mocks.mock_stream_fn_single(Mocks.assistant_message("done"))

      opts =
        base_opts(
          model: @model,
          stream_fn: fn model, context, options ->
            send(owner, {:child_tools, Enum.map(context.tools, & &1.name)})
            response.(model, context, options)
          end
        )

      result =
        execute(cwd, opts, %{
          "prompt" => "Lead",
          "agent" => "lead",
          "async" => false,
          "auto_followup" => false
        })

      assert result.details.status == "completed"
      assert_receive {:child_tools, names}, 2_000
      assert "task" in names
      refute "write" in names

      assert {:ok, capped} =
               Params.validate_run_params(%{"prompt" => "Lead", "agent" => "lead"}, cwd,
                 settings_manager: settings(),
                 task_depth: 1
               )

      refute ToolPolicy.allowed?(capped.tool_policy, "task")
      assert capped.task_allowed_agents == nil
    end

    test "a child with a spawns allowlist must name an allowed agent" do
      opts =
        base_opts(
          task_depth: 1,
          task_allowed_agents: ["scout"],
          run_override: fn _, _ -> result("done") end
        )

      assert {:error, "Subagent 'reviewer' is not in this session's spawns list: scout"} =
               execute("/tmp", opts, %{"prompt" => "x", "agent" => "reviewer"})

      assert {:error, "agent is required; this session may spawn only: scout"} =
               execute("/tmp", opts, %{"prompt" => "x"})

      assert {:error, _} =
               execute("/tmp", opts, %{
                 "tasks" => [%{"prompt" => "x", "agent" => "scout"}, %{"prompt" => "y"}]
               })

      assert %AgentToolResult{details: %{task_id: _}} =
               execute("/tmp", opts, %{
                 "prompt" => "x",
                 "agent" => "scout",
                 "auto_followup" => false
               })
    end

    @tag :tmp_dir
    test "child depth and spawns restrictions survive extension reload", %{tmp_dir: cwd} do
      define(cwd, "lead", "description: Lead\nspawns: [scout]\n")

      opts =
        base_opts(
          model: @model,
          stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("done"))
        )

      assert {:ok, validated} =
               Params.validate_run_params(%{"prompt" => "Lead", "agent" => "lead"}, cwd, opts)

      child =
        start_supervised!({CodingAgent.Session, Params.build_session_opts(cwd, opts, validated)})

      for reload <- [false, true] do
        if reload, do: assert({:ok, _} = CodingAgent.Session.reload_extensions(child))
        state = CodingAgent.Session.get_state(child)
        assert state.task_depth == 1
        task = Enum.find(state.tools, &(&1.name == "task"))

        assert {:error, denied} =
                 task.execute.(unique_id(), %{"prompt" => "x", "agent" => "reviewer"}, nil, nil)

        assert denied =~ "not in this session's spawns list"
      end
    end

    @tag :tmp_dir
    test "resumed user forks can delegate without relaxing bootstrap isolation", %{tmp_dir: cwd} do
      source = Path.join(cwd, "source.jsonl")
      fork = Path.join(cwd, "fork.jsonl")
      :ok = CodingAgent.SessionManager.save_to_file(source, CodingAgent.SessionManager.new(cwd))
      assert {:ok, _} = CodingAgent.SessionManager.fork_file(source, fork)

      opts =
        base_opts(
          model: @model,
          stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("done"))
        )

      session =
        start_supervised!(
          {CodingAgent.Session, Keyword.merge(opts, cwd: cwd, session_file: fork)}
        )

      state = CodingAgent.Session.get_state(session)
      assert state.session_scope == :subagent
      refute state.system_prompt =~ "## MEMORY.md"
      task = Enum.find(state.tools, &(&1.name == "task"))

      result =
        task.execute.(
          unique_id(),
          %{"prompt" => "x", "async" => false, "auto_followup" => false},
          nil,
          nil
        )

      assert result.details.status == "completed"
    end
  end

  describe "structured output retries" do
    test "re-prompts the same child session until its output validates" do
      owner = self()

      responses =
        Mocks.mock_stream_fn([
          Mocks.assistant_message("The answer is 42."),
          Mocks.assistant_message(~s({"answer":42}))
        ])

      opts =
        base_opts(
          model: @model,
          stream_fn: fn model, context, options ->
            send(owner, {:model_call, context.messages})
            responses.(model, context, options)
          end
        )

      result = execute("/tmp", opts, schema_params())

      assert result.details.status == "completed"
      assert result.details.structured_output == %{"answer" => 42}
      assert_receive {:model_call, _first}, 2_000
      assert_receive {:model_call, second}, 2_000
      correction = inspect(second)
      assert correction =~ "failed validation against the required output schema"
      assert correction =~ "response is not valid JSON"
      assert correction =~ "The answer is 42."
    end

    test "strict mode fails after two corrections" do
      owner = self()
      invalid = Mocks.mock_stream_fn_single(Mocks.assistant_message("still prose"))

      opts =
        base_opts(
          model: @model,
          stream_fn: fn model, context, options ->
            send(owner, :model_call)
            invalid.(model, context, options)
          end
        )

      assert {:error, message} = execute("/tmp", opts, schema_params())
      assert message =~ "not valid JSON"

      for _attempt <- 1..3, do: assert_received(:model_call)
      refute_received :model_call
    end

    test "permissive mode returns the text and the validation error" do
      opts =
        base_opts(
          model: @model,
          stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message(~s({"answer":"x"})))
        )

      result = execute("/tmp", opts, Map.put(schema_params(), "schema_mode", "permissive"))

      assert result.details.status == "completed"
      assert result.details.structured_output_error =~ "type mismatch"
      refute Map.has_key?(result.details, :structured_output)
      assert [%TextContent{text: ~s({"answer":"x"})}] = result.content

      assert {:error, "schema_mode must be one of: strict, permissive"} =
               execute("/tmp", opts, Map.put(schema_params(), "schema_mode", "loose"))
    end
  end

  describe "agent:// results" do
    test "owners read completed output and structured fields; foreign callers cannot" do
      output = ~s({"answer":42,"items":[{"name":"lib"}]})
      opts = base_opts(agent_id: "profile-a", run_override: fn _, _ -> result(output) end)

      receipt =
        execute("/tmp", opts, %{
          "prompt" => "Find",
          "name" => "Finder",
          "output_schema" => %{"type" => "object"},
          "auto_followup" => false
        })

      id = receipt.details.task_id
      execute("/tmp", opts, %{"action" => "join", "task_ids" => [id]})

      for address <- ["agent://#{id}", "agent://Finder"] do
        read = Messaging.read(address, opts)
        assert [%TextContent{text: text}] = read.content
        assert text =~ "agent://#{id} (Finder) status: completed"
        assert text =~ output
        assert read.details.status == "completed"
        assert read.details.structured_output["answer"] == 42
        assert [%{task_id: ^id, name: "Finder"}] = read.details.agents
      end

      field = Messaging.read("agent://#{id}/items/0/name", opts)
      assert [%TextContent{text: "lib"}] = field.content
      assert field.details.value == "lib"

      assert [%TextContent{text: "42"}] = Messaging.read("agent://Finder/answer", opts).content

      assert {:error, message} = Messaging.read("agent://#{id}/items/3", opts)
      assert message =~ "Path segment '3' not found"

      foreign = Keyword.put(opts, :parent_session, unique_id())

      for address <- ["agent://#{id}", "agent://#{id}/answer", "agent://Finder"] do
        assert {:error, _} = Messaging.read(address, foreign)
      end

      assert {:error, "Unknown task: #{id}"} == Messaging.read("agent://#{id}/answer", foreign)
    end

    test "a unique live child wins over a completed child with the same name" do
      owner = self()
      opts = base_opts(run_override: fn _, _ -> result("first") end)

      execute("/tmp", opts, %{
        "prompt" => "x",
        "name" => "Worker",
        "async" => false,
        "auto_followup" => false
      })

      live_opts =
        Keyword.put(opts, :run_override, fn _, _ ->
          send(owner, {:live_worker, self()})

          receive do
            :finish -> result("second")
          after
            2_000 -> {:error, "test worker was not released"}
          end
        end)

      second =
        execute("/tmp", live_opts, %{
          "prompt" => "y",
          "name" => "Worker",
          "auto_followup" => false
        })

      assert_receive {:live_worker, worker}

      try do
        read = Messaging.read("agent://Worker", opts)
        assert read.details.task_id == second.details.task_id
        assert read.details.status == "running"
      after
        send(worker, :finish)
      end

      execute("/tmp", opts, %{"action" => "join", "task_ids" => [second.details.task_id]})

      assert {:error, ambiguous} = Messaging.read("agent://Worker", opts)
      assert ambiguous =~ "Ambiguous"
    end
  end

  defp schema_params do
    %{
      "prompt" => "Compute",
      "output_schema" => @schema,
      "async" => false,
      "auto_followup" => false
    }
  end

  defp define(cwd, id, frontmatter) do
    dir = Path.join(cwd, ".lemon/agents")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, id <> ".md"), "---\n" <> frontmatter <> "---\nDo the work.\n")
  end

  defp persona(fields) do
    Map.merge(
      %{
        id: "planner",
        description: "Planner",
        prompt: "Plan the work.",
        model: nil,
        role: nil,
        tools: nil,
        read_only: false,
        source: :project,
        thinking_level: nil,
        spawns: nil,
        output_schema: nil
      },
      fields
    )
  end

  defp settings(task \\ %{}) do
    defaults = %SettingsManager{}
    %{defaults | task: Map.merge(defaults.task, task)}
  end

  defp base_opts(extra) do
    Keyword.merge([parent_session: unique_id(), settings_manager: settings()], extra)
  end

  defp execute(cwd, opts, params), do: TaskTool.execute(unique_id(), params, nil, nil, cwd, opts)
  defp result(text), do: %AgentToolResult{content: [%TextContent{text: text}], details: %{}}
  defp unique_id, do: "runtime-#{System.unique_integer([:positive, :monotonic])}"
end
