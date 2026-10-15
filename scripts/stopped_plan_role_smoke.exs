# Run manually after integration: MIX_ENV=test mix run --no-start scripts/stopped_plan_role_smoke.exs
# No ExUnit, LLM response, provider login or model-network request is required.
defmodule LemonScripts.StoppedPlanRoleSmoke do
  alias CodingAgent.{ControlPlaneProvider, Session, SessionManager}
  alias LemonControlPlane.Methods.SessionsPlan
  alias LemonCore.SessionLifecycle

  def main do
    root =
      Path.join(
        System.tmp_dir!(),
        "lemon-stopped-plan-smoke-#{System.unique_integer([:positive])}"
      )

    home = Path.join(root, "home")
    cwd = Path.join(root, "project")
    File.mkdir_p!(Path.join(home, ".lemon"))
    File.mkdir_p!(Path.join(cwd, ".lemon"))
    System.put_env("HOME", home)
    System.put_env("LEMON_AGENT_DIR", Path.join(home, ".lemon/agent"))
    System.put_env("LEMON_STORE_PATH", Path.join(root, "store"))
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    System.put_env("LEMON_FEATURE_SESSION_SEARCH", "off")
    Application.put_env(:lemon_core, :paths, home_dir: home)

    Enum.each(
      ~w(LEMON_DEFAULT_MODEL LEMON_DEFAULT_PROVIDER OPENAI_API_KEY ANTHROPIC_API_KEY
                 OPENAI_CODEX_API_KEY CHATGPT_TOKEN GOOGLE_API_KEY),
      &System.delete_env/1
    )

    File.write!(
      Path.join(home, ".lemon/config.toml"),
      "[model_roles]\nplan = \"openai:gpt-4o\"\n"
    )

    configure(cwd, "@project-planner")

    try do
      {:ok, _} = Application.ensure_all_started(:coding_agent)
      :ok = LemonCore.AgentRuntime.register(ControlPlaneProvider)
      run(cwd)
    after
      File.rm_rf!(root)
    end
  end

  defp run(cwd) do
    key = "agent:stopped-plan-smoke:main"
    params = %{"sessionKey" => key, "cwd" => cwd}
    {:ok, %{"plan" => %{"mode" => "plan"}}} = plan(params, "enter")
    %{run_count: 0} = SessionLifecycle.get(key)
    {:ok, row} = SessionLifecycle.patch(key, %{title: "Offline plan-role proof"})
    "Offline plan-role proof" = row.title
    manager = load(cwd, key)
    %{"provider" => "smoke-plan", "model" => "execution"} = execution(manager)

    %{provider: "smoke-plan", model_id: "planning"} =
      SessionManager.build_session_context(manager).model

    bytes = File.read!(manager.file_path)
    {:ok, %{"plan" => %{"mode" => "plan"}}} = plan(params, "enter")
    ^bytes = File.read!(manager.file_path)

    opts = [
      cwd: cwd,
      session_key: key,
      session_file: manager.file_path,
      workspace_dir: Path.join(cwd, "profile-workspace"),
      tools: [],
      system_prompt: "Offline stopped-plan smoke.",
      stream_fn: fn _, _, _ -> raise "unexpected model response request" end
    ]

    with_session(opts, fn session ->
      "planning" = Session.get_state(session).model.id
      "planning" = LemonAgent.Agent.get_state(Session.get_state(session).agent).model.id
      :ok = Session.save(session)
    end)

    # Resume has stopped again: an offline exit must restore the saved descriptor.
    {:ok, %{"plan" => %{"mode" => "code"}}} = plan(params, "exit")

    %{provider: "smoke-plan", model_id: "execution"} =
      SessionManager.build_session_context(load(cwd, key)).model

    with_session(opts, fn session ->
      "execution" = Session.get_state(session).model.id
      "execution" = LemonAgent.Agent.get_state(Session.get_state(session).agent).model.id
      # Also prove live entry -> stopped exit preserves the execution model.
      {:ok, %{"mode" => "plan"}} = Session.plan(session, :enter)
      :ok = Session.save(session)
    end)

    {:ok, %{"plan" => %{"mode" => "code"}}} = plan(params, "exit")

    # A stopped entry can be approved after restart; this invokes the same
    # Session callback used by propose_plan after the user's approval decision.
    {:ok, %{"plan" => %{"mode" => "plan"}}} = plan(params, "enter")

    with_session(opts, fn session ->
      "planning" = Session.get_state(session).model.id

      proposal = %{
        "path" => Path.join(CodingAgent.Session.Planning.plan_dir(load(cwd, key)), "approved.md"),
        "content" => "# Approved offline plan"
      }

      :ok = GenServer.call(session, {:resolve_plan_proposal, :approve, proposal})
      "execution" = Session.get_state(session).model.id
      "execution" = LemonAgent.Agent.get_state(Session.get_state(session).agent).model.id
      :ok = Session.save(session)
    end)

    %{provider: "smoke-plan", model_id: "execution"} =
      SessionManager.build_session_context(load(cwd, key)).model

    configure(cwd, "unknown-provider:missing")
    LemonCore.Config.reload(cwd)
    before = File.read!(manager.file_path)
    {:error, :invalid_plan_model} = ControlPlaneProvider.session_plan(key, cwd, :enter, [])
    ^before = File.read!(manager.file_path)
    fresh = "agent:stopped-plan-invalid:main"
    {:error, :invalid_plan_model} = ControlPlaneProvider.session_plan(fresh, cwd, :enter, [])
    nil = LemonCore.ChatStateStore.get(fresh)
    nil = SessionLifecycle.get(fresh)
    %{run_count: 0} = SessionLifecycle.get(key)
    {:ok, _} = SessionLifecycle.delete(key)

    IO.puts(
      Jason.encode!(%{
        status: "passed",
        public_plan_method: true,
        lifecycle_metadata: true,
        stopped_enter_resume_exit: true,
        live_enter_stopped_exit: true,
        resumed_approval: true,
        invalid_role_preserved_journal_and_binding: true,
        model_responses: 0
      })
    )
  end

  defp plan(params, action), do: SessionsPlan.handle(Map.put(params, "action", action), %{})

  defp load(cwd, key) do
    id = LemonCore.ChatStateStore.get(key).last_resume_token
    path = SessionManager.session_file_path(cwd, id)
    {:ok, manager} = SessionManager.load_from_file(path)
    %{manager | file_path: path}
  end

  defp execution(manager),
    do: SessionManager.latest_custom_entry(manager, "lemon.plan").data["execution_model"]

  defp with_session(opts, fun) do
    {:ok, session} = Session.start_link(opts)

    try do
      fun.(session)
    after
      GenServer.stop(session)
    end
  end

  defp configure(cwd, selector) do
    File.write!(Path.join(cwd, ".lemon/config.toml"), """
    [defaults]
    model = "smoke-plan:execution"
    [model_roles]
    plan = "#{selector}"
    project-planner = "smoke-plan:planning"
    [providers.smoke-plan]
    api = "openai_completions"
    base_url = "http://127.0.0.1:1/v1"
    auth = "none"
    [[providers.smoke-plan.models]]
    id = "execution"
    [[providers.smoke-plan.models]]
    id = "planning"
    [features]
    session_search = "off"
    [memory]
    auto_recall = false
    [runtime.compaction]
    enabled = false
    [runtime.retry]
    enabled = false
    [runtime.provider_routing]
    enabled = false
    """)
  end
end

LemonScripts.StoppedPlanRoleSmoke.main()
