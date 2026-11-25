defmodule CodingAgent.ModelProvenanceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodingAgent.ModelProvenance
  alias CodingAgent.SettingsManager
  alias CodingAgent.Tools.Task.Params

  @moduletag :tmp_dir

  @operator_default %{provider: :openai, model_id: "gpt-4o", base_url: nil}

  defp settings(task \\ %{}, roles \\ %{}) do
    %SettingsManager{
      default_model: @operator_default,
      model_roles: roles,
      task: Map.merge(%SettingsManager{}.task, task)
    }
  end

  # Merged settings carrying the provenance pair of one config load.
  defp layered(merged, operator, project),
    do: %{merged | provenance: %{operator: operator, project: project}}

  defp write_persona(cwd, dir, id, frontmatter) do
    File.mkdir_p!(Path.join(cwd, dir))

    File.write!(Path.join([cwd, dir, "#{id}.md"]), """
    ---
    name: #{id}
    description: #{id}
    #{frontmatter}
    ---
    Work.
    """)
  end

  # Resolves the child's model exactly as a launch does.
  defp child(cwd, params, settings, opts \\ []) do
    opts = opts ++ [settings_manager: settings]
    {:ok, validated} = Params.validate_run_params(Map.put(params, "prompt", "Go"), cwd, opts)
    {model, _, _} = Params.resolve_task_model(cwd, opts, validated)
    {model, validated}
  end

  defp canonical(%LemonAi.Types.Model{provider: p, id: id}), do: "#{p}/#{id}"
  defp canonical(nil), do: nil
  defp canonical(spec), do: ModelProvenance.canonical(spec, settings())

  test "project personas in all three formats cannot switch provider while the gate is off",
       %{tmp_dir: cwd} do
    write_persona(cwd, ".lemon/agents", "native", "model: anthropic:claude-sonnet-4-5")
    write_persona(cwd, ".omp/agents", "omp", "model: anthropic:claude-sonnet-4-5")
    write_persona(cwd, ".claude/agents", "claude", "model: anthropic:claude-sonnet-4-5")

    for id <- ~w(native omp claude) do
      {{model, _}, log} = with_log(fn -> child(cwd, %{"agent" => id}, settings()) end)
      assert canonical(model) == "openai/gpt-4o", "#{id} persona applied #{inspect(model)}"
      assert log =~ "comes from project configuration"
    end
  end

  test "a provider switch must resolve to an allowlisted model", %{tmp_dir: cwd} do
    write_persona(cwd, ".lemon/agents", "switch", "model: anthropic:claude-sonnet-4-5")
    allow_openai = settings(%{per_call_model: "on", per_call_model_allow: ["openai/gpt-4o-mini"]})

    {{model, _}, _} = with_log(fn -> child(cwd, %{"agent" => "switch"}, allow_openai) end)
    assert canonical(model) == "openai/gpt-4o"

    allow_it =
      settings(%{per_call_model: "on", per_call_model_allow: ["anthropic/claude-sonnet-4-5"]})

    {model, _} = child(cwd, %{"agent" => "switch"}, allow_it)
    assert canonical(model) == "anthropic/claude-sonnet-4-5"
  end

  test "role indirection through project model_roles is gated, operator roles are not",
       %{tmp_dir: cwd} do
    write_persona(cwd, ".lemon/agents", "worker", "tools: [read]")
    roles = %{"coding" => "anthropic:claude-sonnet-4-5"}

    # An operator agent_models entry naming a role the project redefines, with
    # the role allowlisted literally by the operator.
    gated =
      settings(
        %{
          per_call_model: "on",
          per_call_model_allow: ["@coding"],
          agent_models: %{"worker" => "@coding"}
        },
        roles
      )

    project_gated = layered(gated, settings(), %{"model_roles" => roles})

    {{model, _}, log} = with_log(fn -> child(cwd, %{"agent" => "worker"}, project_gated) end)
    assert canonical(model) == "openai/gpt-4o"
    assert log =~ "project configuration"

    {model, _} = child(cwd, %{"agent" => "worker"}, gated)
    assert canonical(model) == "anthropic/claude-sonnet-4-5"

    # The explicit preflight rejects the same literal role.
    assert {:error, message} =
             Params.check_per_call_model(%{"model" => "@coding"}, cwd,
               settings_manager: project_gated
             )

    assert message =~ "per_call_model_allow"

    # The implicit `@task` default through a project role is gated too.
    task_roles = %{"task" => "anthropic:claude-sonnet-4-5"}

    {{model, _}, _} =
      with_log(fn ->
        child(
          cwd,
          %{},
          layered(settings(%{}, task_roles), settings(), %{"model_roles" => task_roles})
        )
      end)

    assert canonical(model) == "openai/gpt-4o"

    # The same role defined by the operator stays operator-trusted.
    {model, _} = child(cwd, %{}, settings(%{}, task_roles))
    assert canonical(model) == "anthropic/claude-sonnet-4-5"
  end

  test "project runtime.task.agent_models is gated; operator agent_models is not",
       %{tmp_dir: cwd} do
    write_persona(cwd, ".lemon/agents", "worker", "tools: [read]")
    task = %{agent_models: %{"worker" => "anthropic:claude-sonnet-4-5"}}
    project = %{"runtime" => %{"task" => %{"agent_models" => task.agent_models}}}

    {{model, _}, _} =
      with_log(fn ->
        child(cwd, %{"agent" => "worker"}, layered(settings(task), settings(), project))
      end)

    assert canonical(model) == "openai/gpt-4o"

    {model, _} = child(cwd, %{"agent" => "worker"}, settings(task))
    assert canonical(model) == "anthropic/claude-sonnet-4-5"
  end

  test "a project default model inherited by a child falls back to the operator default",
       %{tmp_dir: cwd} do
    project_default = %{provider: :anthropic, model_id: "claude-sonnet-4-5", base_url: nil}

    merged =
      layered(%{settings() | default_model: project_default}, settings(), %{
        "defaults" => %{"model" => "anthropic:claude-sonnet-4-5"}
      })

    parent = LemonAgent.ModelRuntime.ModelResolver.resolve_session_model(nil, merged)
    assert ModelProvenance.origin(nil, merged) == :project

    # With and without a recorded parent origin.
    for opts <- [[model: parent], [model: parent, model_origin: :project]] do
      {{model, _}, _} = with_log(fn -> child(cwd, %{}, merged, opts) end)
      assert canonical(model) == "openai/gpt-4o"
    end
  end

  test "a project persona's thinking override applies only when per-call selection is on",
       %{tmp_dir: cwd} do
    write_persona(cwd, ".claude/agents", "deep", "thinking: xhigh")
    write_persona(cwd, ".omp/agents", "deeper", "thinking: max")

    for id <- ~w(deep deeper) do
      {{_, validated}, log} = with_log(fn -> child(cwd, %{"agent" => id}, settings()) end)
      assert validated.thinking_level == nil
      assert log =~ "thinking level"

      {_, validated} = child(cwd, %{"agent" => id}, settings(%{per_call_model: "on"}))
      assert validated.thinking_level == "xhigh"
    end
  end

  test "an inherited project defaults.thinking_level is gated like persona thinking",
       %{tmp_dir: cwd} do
    project = %{"defaults" => %{"thinking_level" => "xhigh"}}
    operator = %{settings() | default_thinking_level: :low}
    merged = layered(%{settings() | default_thinking_level: :xhigh}, operator, project)
    opts = fn s -> [settings_manager: s, model: "openai:gpt-4o"] end

    {:ok, validated} = Params.validate_run_params(%{"prompt" => "Go"}, cwd, opts.(merged))

    {child_opts, log} =
      with_log(fn -> Params.build_session_opts(cwd, opts.(merged), validated) end)

    assert child_opts[:thinking_level] == :low
    assert log =~ "project defaults"

    on = %{merged | task: %{merged.task | per_call_model: "on"}}
    {:ok, validated} = Params.validate_run_params(%{"prompt" => "Go"}, cwd, opts.(on))
    assert Params.build_session_opts(cwd, opts.(on), validated)[:thinking_level] == nil

    # Without a project level the operator default is inherited untouched.
    plain = opts.(layered(merged, operator, %{}))
    assert Params.build_session_opts(cwd, plain, validated)[:thinking_level] == nil
  end

  test "a parent model chosen through a project role keeps its provenance in children",
       %{tmp_dir: cwd} do
    # The operator's default is @coding (OpenAI); the repository changes only
    # model_roles.coding, to Anthropic.
    operator = %{settings(%{}, %{"coding" => "openai:gpt-4o-mini"}) | default_model: "@coding"}

    merged =
      layered(
        %{operator | model_roles: %{"coding" => "anthropic:claude-sonnet-4-5"}},
        operator,
        %{
          "model_roles" => %{"coding" => "anthropic:claude-sonnet-4-5"}
        }
      )

    # The parent session records where its default came from.
    assert ModelProvenance.origin(nil, merged) == :project
    parent = LemonAgent.ModelRuntime.ModelResolver.resolve_session_model(nil, merged)
    assert canonical(parent) == "anthropic/claude-sonnet-4-5"

    opts = [settings_manager: merged, model: parent, model_origin: :project]
    {:ok, validated} = Params.validate_run_params(%{"prompt" => "Go"}, cwd, opts)

    {{model, _, child_origin}, log} =
      with_log(fn -> Params.resolve_task_model(cwd, opts, validated) end)

    assert canonical(model) == "openai/gpt-4o-mini"
    assert child_origin == :operator
    assert log =~ "project configuration"
    assert Params.build_session_opts(cwd, opts, validated)[:model_origin] == :operator

    # An operator-origin parent model is inherited untouched.
    {model, _, :operator} =
      Params.resolve_task_model(cwd, Keyword.put(opts, :model_origin, :operator), validated)

    assert canonical(model) == "anthropic/claude-sonnet-4-5"
  end

  # Operator default @coding (OpenAI), `smol` unconfigured; the repository
  # overrides only `model_roles.coding` (Anthropic). The parent session runs on
  # that project-origin model.
  defp project_role_parent(task, operator_roles \\ %{}) do
    roles = Map.put(operator_roles, "coding", "openai:gpt-4o-mini")
    operator = %{settings(task, roles) | default_model: "@coding"}
    project = %{"model_roles" => %{"coding" => "anthropic:claude-sonnet-4-5"}}

    merged =
      layered(
        %{operator | model_roles: Map.merge(roles, project["model_roles"])},
        operator,
        project
      )

    parent = LemonAgent.ModelRuntime.ModelResolver.resolve_session_model(nil, merged)
    assert canonical(parent) == "anthropic/claude-sonnet-4-5"
    assert ModelProvenance.origin(nil, merged) == :project
    {merged, [model: parent, model_origin: :project]}
  end

  @gate_settings [
    {"off", %{}},
    {"restrictive allowlist",
     %{per_call_model: "on", per_call_model_allow: ["@smol", "@quick", "openai/gpt-4o-mini"]}}
  ]

  test "bundled sonic's unconfigured @smol cannot ride a project-origin parent model",
       %{tmp_dir: cwd} do
    for {label, task} <- @gate_settings do
      {merged, parent_opts} = project_role_parent(task)

      assert {_, :project} =
               ModelProvenance.resolve("@smol", merged, {parent_opts[:model], :project})

      {{model, _}, log} =
        with_log(fn -> child(cwd, %{"agent" => "sonic"}, merged, parent_opts) end)

      assert canonical(model) == "openai/gpt-4o-mini", "#{label}: #{inspect(model)}"
      assert log =~ "comes from project configuration"

      # The same fallback to an operator-origin parent stays operator-owned.
      operator_parent = Keyword.put(parent_opts, :model_origin, :operator)
      {model, _} = child(cwd, %{"agent" => "sonic"}, merged, operator_parent)
      assert canonical(model) == "anthropic/claude-sonnet-4-5"
    end
  end

  test "an operator alias ending at an unconfigured built-in role is judged by its fallback",
       %{tmp_dir: cwd} do
    for {label, task} <- @gate_settings do
      # Operator: quick -> @smol (unconfigured); task-executor launches via @quick.
      task = Map.put(task, :agent_models, %{"task-executor" => "@quick"})
      {merged, parent_opts} = project_role_parent(task, %{"quick" => "@smol"})

      {{model, _}, log} =
        with_log(fn -> child(cwd, %{"agent" => "task-executor"}, merged, parent_opts) end)

      assert canonical(model) == "openai/gpt-4o-mini", "#{label}: #{inspect(model)}"
      assert log =~ "comes from project configuration"

      if task[:per_call_model] == "on" do
        # An allowlisted literal alias is not a pass for a project-origin fallback.
        project_opts = [settings_manager: merged] ++ parent_opts
        operator_opts = Keyword.put(project_opts, :model_origin, :operator)

        assert {:error, _} =
                 Params.check_per_call_model(%{"model" => "@quick"}, cwd, project_opts)

        assert :ok = Params.check_per_call_model(%{"model" => "@quick"}, cwd, operator_opts)
      end
    end
  end

  test "operator routing rules resolve against the operator layer only" do
    operator =
      %{settings(%{}, %{"fast" => "openai:gpt-4o-mini"}) | model_routing: %{}}

    merged =
      layered(
        %{
          operator
          | model_roles: %{"fast" => "anthropic:claude-sonnet-4-5"},
            model_routing: %{
              "enabled" => true,
              "max_cost_usd" => 50,
              "rules" => [%{"model" => "@fast"}]
            }
        },
        operator,
        # Provenance no longer names the override (it was removed from disk
        # after the load): routing still resolves against the operator layer.
        %{}
      )

    routing = ModelProvenance.prepare_routing(merged)
    assert inspect(routing) =~ "gpt-4o-mini"
    refute inspect(routing) =~ "claude-sonnet-4-5"
    assert inspect(routing) =~ "max_cost_usd: 50"
  end
end
