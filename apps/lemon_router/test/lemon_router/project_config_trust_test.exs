defmodule LemonRouter.ProjectConfigTrustTest do
  use ExUnit.Case, async: false

  alias CodingAgent.SettingsManager

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    global = Path.join(tmp, "home/.lemon/config.toml")
    project = Path.join(tmp, "project")
    File.mkdir_p!(Path.dirname(global))
    File.mkdir_p!(Path.join(project, ".lemon"))
    saved_paths = Application.get_env(:lemon_core, :paths)
    Application.put_env(:lemon_core, :paths, global_config: global)

    on_exit(fn ->
      if saved_paths,
        do: Application.put_env(:lemon_core, :paths, saved_paths),
        else: Application.delete_env(:lemon_core, :paths)
    end)

    %{global: global, project: project, tmp: tmp}
  end

  defp configure(ctx, global, project) do
    File.write!(ctx.global, global)
    File.write!(Path.join(ctx.project, ".lemon/config.toml"), project)
    LemonCore.ConfigCache.invalidate(ctx.project)
    SettingsManager.load(ctx.project)
  end

  @routing_keys """
  [providers.openai]
  api_key = "operator-openai-key"

  [providers.anthropic]
  api_key = "operator-anthropic-key"
  """

  defmodule CapturingRouter do
    @moduledoc false
    # Stands in for the run orchestrator: hands the agent tool's request to the test.
    def submit(%LemonCore.RunRequest{} = request) do
      send(:project_trust_router_owner, {:router_submit, request})
      {:ok, "provenance-run-#{System.unique_integer([:positive])}"}
    end
  end

  test "a delegated operator profile role never resolves through a project override", ctx do
    settings =
      configure(
        ctx,
        """
        [defaults]
        provider = "openai"
        model = "openai:gpt-4o"

        [model_roles]
        coding = "openai:gpt-4o-mini"

        [profiles.oracle]
        name = "Oracle"
        model = "@coding"

        #{@routing_keys}
        """,
        """
        [model_roles]
        coding = "anthropic:claude-sonnet-4-20250514"
        """
      )

    assert settings.task.per_call_model == "off"
    use_agent_profiles_from(ctx.project)
    assert eventually(fn -> LemonRouter.AgentProfiles.get("oracle")[:model] == "@coding" end)

    # The parent delegates to `oracle` without a model; the router fills in the
    # operator profile's `@coding` and marks it operator-sourced.
    {request, command, call} = delegate_and_run(ctx.project, settings, %{"agent_id" => "oracle"})

    assert request.model == nil
    assert command.meta.model == "@coding"
    assert command.meta.model_source == :operator
    assert call == {"openai", "gpt-4o-mini"}
  end

  test "a delegated persona alias is resolved where it was admitted, not in the child cwd",
       ctx do
    settings =
      configure(
        ctx,
        """
        [defaults]
        provider = "openai"
        model = "openai:gpt-4o"

        [model_roles]
        coding = "openai:gpt-4o-mini"

        [runtime.task]
        per_call_model = "on"
        per_call_model_allow = ["openai/gpt-4o-mini", "@coding"]

        [profiles.oracle]
        name = "Oracle"

        #{@routing_keys}
        """,
        ""
      )

    # The child's cwd is a workspace subdirectory with its own project config
    # redefining the role the persona names, and the persona itself.
    child_cwd = Path.join(ctx.project, "sub")
    File.mkdir_p!(Path.join(child_cwd, ".lemon/agents"))

    File.write!(
      Path.join(child_cwd, ".lemon/config.toml"),
      "[model_roles]\ncoding = \"anthropic:claude-sonnet-4-20250514\"\n"
    )

    File.write!(
      Path.join(child_cwd, ".lemon/agents/coder.md"),
      "---\ndescription: Coder\nmodel: \"@coding\"\n---\nCode."
    )

    LemonCore.ConfigCache.invalidate(child_cwd)
    use_agent_profiles_from(ctx.project)
    assert eventually(fn -> LemonRouter.AgentProfiles.exists?("oracle") end)

    for params <- [
          %{"agent_id" => "oracle", "role" => "coder", "cwd" => child_cwd},
          %{"agent_id" => "oracle", "model" => "@coding", "cwd" => child_cwd}
        ] do
      {request, _command, call} = delegate_and_run(ctx.project, settings, params)
      assert call == {"openai", "gpt-4o-mini"}, inspect(params)
      assert request.model == "openai:gpt-4o-mini"
    end
  end

  defp use_agent_profiles_from(cwd) do
    previous_cwd = Application.get_env(:lemon_router, :agent_profiles_cwd)
    Application.put_env(:lemon_router, :agent_profiles_cwd, cwd)
    LemonRouter.AgentProfiles.reload()

    on_exit(fn ->
      if previous_cwd,
        do: Application.put_env(:lemon_router, :agent_profiles_cwd, previous_cwd),
        else: Application.delete_env(:lemon_router, :agent_profiles_cwd)

      LemonRouter.AgentProfiles.reload()
    end)
  end

  # The parent's agent tool submits a delegated run; the real router builds it
  # and the real executor starts the destination session. Returns the agent
  # tool's request, the router's execution command and the {provider, model}
  # of the destination's provider request.
  defp delegate_and_run(parent_cwd, settings, params) do
    unless Process.whereis(:project_trust_router_owner),
      do: Process.register(self(), :project_trust_router_owner)

    result =
      CodingAgent.Tools.Agent.execute(
        "delegate-#{System.unique_integer([:positive])}",
        Map.merge(%{"prompt" => "Inspect", "auto_followup" => false}, params),
        nil,
        nil,
        parent_cwd,
        run_orchestrator: CapturingRouter,
        settings_manager: settings,
        session_key: "agent:main:main"
      )

    assert_receive {:router_submit, %LemonCore.RunRequest{} = request},
                   5_000,
                   "agent tool result: #{inspect(result)}"

    assert {:ok, submission} =
             LemonRouter.SubmissionBuilder.build(request, %{
               run_supervisor: LemonRouter.RunSupervisor,
               run_process_module: LemonRouter.RunProcess,
               run_process_opts: %{}
             })

    command = submission.execution_request
    parent = self()

    stream_fn = fn model, _context, _options ->
      send(parent, {:provider_call, to_string(model.provider), model.id})

      response = %LemonAi.Types.AssistantMessage{
        content: [%LemonAi.Types.TextContent{text: "done"}],
        stop_reason: :stop,
        model: model.id,
        provider: model.provider
      }

      {:ok, stream} = LemonAi.EventStream.start_link()
      LemonAi.EventStream.push(stream, {:start, response})
      LemonAi.EventStream.push(stream, {:done, :stop, response})
      LemonAi.EventStream.complete(stream, response)
      {:ok, stream}
    end

    assert {:ok, _run_ref, %{runner_pid: runner}} =
             command
             |> CodingAgent.Executor.start_run(%{stream_fn: stream_fn}, self())

    on_exit(fn -> CodingAgent.Session.Presentation.safe_stop_session(runner) end)
    assert_receive {:provider_call, provider, model}, 10_000
    {request, command, {provider, model}}
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end
end
