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

  describe "persona and config defaults" do
    test "persona thinking level and output schema apply unless explicitly overridden" do
      persona = persona(%{role: "coding", thinking_level: "high", output_schema: @schema})

      launch = Params.persona_launch(persona, %{}, settings().task, 0)
      assert launch.thinking_level == "high"
      assert launch.output_schema == @schema
      assert launch.model == "@coding"

      explicit =
        Params.persona_launch(
          persona,
          %{thinking_level: "low", output_schema: false, model: "openai:gpt-4o"},
          settings().task,
          0
        )

      assert explicit.thinking_level == "low"
      assert explicit.output_schema == false
      assert explicit.model == "openai:gpt-4o"

      validated = Map.merge(launch, %{persona: persona, name: nil})

      session_settings = %SettingsManager{
        model_roles: %{"coding" => "openai:gpt-4o-mini"}
      }

      child_opts =
        Params.build_session_opts("/tmp", [settings_manager: session_settings], validated)

      assert child_opts[:thinking_level] == "high"
      assert child_opts[:model].id == "gpt-4o-mini"
      assert child_opts[:system_prompt] =~ "ONLY valid JSON"
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

      unlimited =
        opts
        |> Keyword.put(:settings_manager, settings(%{max_depth: -1}))
        |> Keyword.put(:task_depth, 10)

      assert %AgentToolResult{details: %{task_id: _}} =
               execute("/tmp", unlimited, %{"prompt" => "x", "auto_followup" => false})
    end

    test "children at the depth cap never receive task, even when tool_policy asks" do
      params = %{"prompt" => "x", "tool_policy" => %{"allow" => "all"}}

      assert {:ok, below} =
               Params.validate_run_params(params, "/tmp", settings_manager: settings())

      assert ToolPolicy.allowed?(below.tool_policy, "task")

      assert {:ok, capped} =
               Params.validate_run_params(params, "/tmp",
                 settings_manager: settings(),
                 task_depth: 1
               )

      refute ToolPolicy.allowed?(capped.tool_policy, "task")

      child_opts =
        Params.build_session_opts("/tmp", [task_depth: 1, settings_manager: settings()], capped)

      assert child_opts[:task_depth] == 2
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
    test "grant task to non-read-only personas with their allowlist" do
      lead = persona(%{id: "lead", tools: ["read", "bash"], spawns: ["scout"]})
      launch = Params.persona_launch(lead, %{}, settings().task, 0)

      assert ToolPolicy.allowed?(launch.tool_policy, "task")
      assert ToolPolicy.allowed?(launch.tool_policy, "bash")
      refute ToolPolicy.allowed?(launch.tool_policy, "agent")
      refute ToolPolicy.allowed?(launch.tool_policy, "write")
      assert launch.task_allowed_agents == ["scout"]

      open = Params.persona_launch(persona(%{spawns: :all}), %{}, settings().task, 0)
      assert ToolPolicy.allowed?(open.tool_policy, "task")
      assert open.task_allowed_agents == :all

      child_opts =
        Params.build_session_opts("/tmp", [settings_manager: settings()], launch)

      assert child_opts[:task_allowed_agents] == ["scout"]
      assert child_opts[:task_depth] == 1

      for read_only <- [
            persona(%{id: "scout", spawns: :all}),
            persona(%{id: "security-reviewer", spawns: :all}),
            persona(%{read_only: true, spawns: :all})
          ] do
        launch = Params.persona_launch(read_only, %{}, settings().task, 0)
        refute ToolPolicy.allowed?(launch.tool_policy, "task")
        assert launch.task_allowed_agents == nil
      end

      capped = Params.persona_launch(lead, %{}, settings().task, 1)
      refute ToolPolicy.allowed?(capped.tool_policy, "task")
      assert capped.task_allowed_agents == nil

      restricted =
        Params.persona_launch(lead, %{tool_policy: %{"allow" => ["read"]}}, settings().task, 0)

      refute ToolPolicy.allowed?(restricted.tool_policy, "task")
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

      via_read =
        CodingAgent.Tools.Read.execute(
          "r",
          %{"path" => "agent://Finder/answer"},
          nil,
          nil,
          "/tmp",
          opts
        )

      assert [%TextContent{text: "42"}] = via_read.content

      assert {:error, message} = Messaging.read("agent://#{id}/items/3", opts)
      assert message =~ "Path segment '3' not found"

      foreign = Keyword.put(opts, :parent_session, unique_id())

      for address <- ["agent://#{id}", "agent://#{id}/answer", "agent://Finder"] do
        assert {:error, _} = Messaging.read(address, foreign)
      end

      assert {:error, "Unknown task: #{id}"} == Messaging.read("agent://#{id}/answer", foreign)
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
