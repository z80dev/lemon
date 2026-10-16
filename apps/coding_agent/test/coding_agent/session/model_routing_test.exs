defmodule CodingAgent.Session.ModelRoutingTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Session
  alias CodingAgent.SettingsManager
  alias LemonAi.Types.{AssistantMessage, TextContent}

  @moduletag :tmp_dir

  setup %{tmp_dir: cwd} do
    settings = %SettingsManager{
      default_model: %{provider: :openai, model_id: "gpt-4o", base_url: nil},
      providers: %{
        "openai" => %{api_key: "routing-openai-key"},
        "anthropic" => %{api_key: "routing-anthropic-key"}
      },
      provider_routing: %{enabled: false},
      retry_enabled: false,
      compaction_enabled: false,
      model_routing: %{
        "enabled" => true,
        "max_cost_usd" => 100,
        "rules" => [
          %{"model" => "anthropic:claude-sonnet-4-20250514", "contains" => "review"},
          %{"model" => "openai:gpt-4o-mini", "max_chars" => 20}
        ]
      }
    }

    %{cwd: cwd, settings: settings}
  end

  test "routing defaults off and leaves the configured model unchanged", context do
    session = session(context, settings: %{context.settings | model_routing: %{}})
    assert turn(session, "hi").model == "gpt-4o"
    assert_receive {:provider_call, :openai, "gpt-4o", "routing-openai-key"}
  end

  test "rules route every turn and rebuild credentials when switching providers", context do
    session = session(context)
    assert turn(session, "hi").model == "gpt-4o-mini"
    assert_receive {:provider_call, :openai, "gpt-4o-mini", "routing-openai-key"}

    assert turn(session, "REVIEW this change").model == "claude-sonnet-4-20250514"

    assert_receive {:provider_call, :anthropic, "claude-sonnet-4-20250514",
                    "routing-anthropic-key"}

    assert turn(session, String.duplicate("x", 30)).model == "gpt-4o"
    assert_receive {:provider_call, :openai, "gpt-4o", "routing-openai-key"}
  end

  test "a direct explicit model and a later user switch always win", context do
    session = session(context, model: "openai:gpt-4o")
    assert turn(session, "review").model == "gpt-4o"

    auto = session(context)
    assert turn(auto, "hi").model == "gpt-4o-mini"

    model =
      CodingAgent.Session.ModelResolver.resolve_session_model("openai:gpt-4o", context.settings)

    assert :ok = Session.switch_model(auto, model)
    assert turn(auto, "review").model == "gpt-4o"
  end

  test "nullable model provenance preserves legacy explicit selectors", context do
    for explicit <- [nil, true] do
      pinned = session(context, model: "openai:gpt-4o", model_explicit: explicit)
      assert turn(pinned, "hi").model == "gpt-4o"
      assert_receive {:provider_call, :openai, "gpt-4o", _}
    end

    automatic = session(context, model_explicit: nil)
    assert turn(automatic, "hi").model == "gpt-4o-mini"
    assert_receive {:provider_call, :openai, "gpt-4o-mini", _}
  end

  for provenance <- [:omitted, nil] do
    @provenance provenance
    test "parentless Coordinator preserves explicit models with #{@provenance} provenance",
         context do
      settings = %{
        context.settings
        | model_routing: %{
            "enabled" => true,
            "max_cost_usd" => 0,
            "rules" => [%{"model" => "openai:gpt-4o-mini", "contains" => "hi"}]
          }
      }

      opts = [cwd: context.cwd, model: "openai:gpt-4o", settings_manager: settings]
      opts = if @provenance == :omitted, do: opts, else: Keyword.put(opts, :model_explicit, nil)
      coordinator = start_supervised!({CodingAgent.Coordinator, opts})
      owner = self()

      :sys.replace_state(coordinator, fn state ->
        %{
          state
          | session_starter: fn child_opts ->
              send(owner, {:child_opts, child_opts})
              {:error, :admission_failed}
            end
        }
      end)

      CodingAgent.Coordinator.run_subagents(coordinator, [%{prompt: "hi"}])
      assert_receive {:child_opts, child_opts}
      assert child_opts[:model_explicit]
      child = session(context, Keyword.put(child_opts, :register, false))
      assert turn(child, "hi").model == "gpt-4o"
      assert_receive {:provider_call, :openai, "gpt-4o", _}
    end
  end

  test "router-resolved defaults do not masquerade as explicit selections", context do
    session = session(context, model: "openai:gpt-4o", model_explicit: false)
    assert turn(session, "hi").model == "gpt-4o-mini"
  end

  test "delegated defaults retain automatic caps while explicit task models override", context do
    settings = %{
      context.settings
      | model_roles: %{"coding" => "openai:gpt-4o"},
        model_routing: %{
          "enabled" => true,
          "max_cost_usd" => 0.05,
          "rules" => [%{"model" => "openai:gpt-4o-mini", "max_chars" => 20}]
        }
    }

    parent = session(context, settings: settings)
    assert turn(parent, "hi").model == "gpt-4o-mini"
    assert_receive {:provider_call, :openai, "gpt-4o-mini", _}

    opts = [
      parent_session: parent,
      model: Session.get_state(parent).model,
      settings_manager: settings
    ]

    alias CodingAgent.Tools.Task.Params
    persona_dir = Path.join(context.cwd, ".lemon/agents")
    File.mkdir_p!(persona_dir)

    File.write!(Path.join(persona_dir, "architect.md"), """
    ---
    description: Architecture review
    model: openai:gpt-4o
    ---
    Inspect architecture.
    """)

    {:ok, validated} =
      Params.validate_run_params(
        %{"prompt" => String.duplicate("x", 100), "agent" => "architect"},
        context.cwd,
        opts
      )

    assert validated.model == "openai:gpt-4o"
    refute validated.model_explicit

    child_opts = Params.build_session_opts(context.cwd, opts, validated)
    assert child_opts[:model_explicit] == false
    child = session(context, Keyword.put(child_opts, :register, false))
    Session.subscribe(child)
    assert :ok = Session.prompt(child, String.duplicate("x", 100))
    assert_receive {:session_event, _, {:error, :model_routing_cost_cap, _}}, 5_000
    refute_receive {:provider_call, _, _, _}, 50

    File.write!(Path.join(persona_dir, "role-reviewer.md"), """
    ---
    description: Role-based review
    role: coding
    ---
    Inspect architecture.
    """)

    {:ok, role_params} =
      Params.validate_run_params(
        %{"prompt" => String.duplicate("x", 100), "agent" => "role-reviewer"},
        context.cwd,
        opts
      )

    assert role_params.model == "@coding"
    refute role_params.model_explicit
    role_opts = Params.build_session_opts(context.cwd, opts, role_params)
    role_child = session(context, Keyword.put(role_opts, :register, false))
    Session.subscribe(role_child)
    assert :ok = Session.prompt(role_child, String.duplicate("x", 100))
    assert_receive {:session_event, _, {:error, :model_routing_cost_cap, _}}, 5_000
    refute_receive {:provider_call, _, _, _}, 50

    {:ok, explicit_params} =
      Params.validate_run_params(
        %{"prompt" => "hi", "agent" => "architect", "model" => "openai:gpt-4o"},
        context.cwd,
        opts
      )

    explicit_opts = Params.build_session_opts(context.cwd, opts, explicit_params)

    assert explicit_opts[:model_explicit] == true
    explicit = session(context, Keyword.put(explicit_opts, :register, false))
    assert turn(explicit, String.duplicate("x", 100)).model == "gpt-4o"
    assert_receive {:provider_call, :openai, "gpt-4o", _}

    selected =
      CodingAgent.Session.ModelResolver.resolve_session_model("openai:gpt-4o", settings)

    assert :ok = Session.switch_model(parent, selected)
    stale_opts = Keyword.put(opts, :model_explicit, false)
    updated_opts = CodingAgent.Tools.Task.Params.build_session_opts(context.cwd, stale_opts, %{})
    assert updated_opts[:model_explicit] == true
  end

  test "an unaffordable automatic request never reaches a provider", context do
    settings = %{
      context.settings
      | model_routing: %{context.settings.model_routing | "max_cost_usd" => 0}
    }

    session = session(context, settings: settings)
    Session.subscribe(session)
    assert :ok = Session.prompt(session, "hi")
    assert_receive {:session_event, _, {:error, :model_routing_cost_cap, _}}, 5_000
    refute_receive {:provider_call, _, _, _}, 50
  end

  test "explicit choice bypasses an automatic cap, including on durable resume", context do
    settings = %{
      context.settings
      | model_routing: %{context.settings.model_routing | "max_cost_usd" => 0}
    }

    file = Path.join(context.cwd, "explicit.jsonl")
    first = session(context, settings: settings, model: "openai:gpt-4o", session_file: file)
    assert turn(first, "review").model == "gpt-4o"
    :ok = GenServer.stop(first)

    resumed = session(context, settings: settings, session_file: file)
    assert turn(resumed, "hi").model == "gpt-4o"
  end

  test "resuming an automatic session does not turn its default into an explicit pin", context do
    file = Path.join(context.cwd, "automatic.jsonl")
    first = session(context, session_file: file)
    assert turn(first, "hi").model == "gpt-4o-mini"
    :ok = GenServer.stop(first)

    resumed = session(context, session_file: file)
    assert turn(resumed, "hi").model == "gpt-4o-mini"
  end

  test "resetting and resuming an automatic session preserves per-turn routing", context do
    first = session(context)
    assert turn(first, "hi").model == "gpt-4o-mini"
    previous_file = Session.get_state(first).session_file

    assert :ok = Session.reset(first)
    reset_state = Session.get_state(first)
    refute reset_state.session_file == previous_file

    assert %{model_explicit: false} =
             CodingAgent.SessionManager.build_session_context(reset_state.session_manager)

    assert :ok = Session.save(first)
    :ok = GenServer.stop(first)

    resumed = session(context, session_file: reset_state.session_file)

    assert %{model_explicit: false} =
             resumed
             |> Session.get_state()
             |> Map.fetch!(:session_manager)
             |> CodingAgent.SessionManager.build_session_context()

    assert turn(resumed, "review this change").model == "claude-sonnet-4-20250514"

    assert_receive {:provider_call, :anthropic, "claude-sonnet-4-20250514",
                    "routing-anthropic-key"}

    assert turn(resumed, "hi").model == "gpt-4o-mini"
  end

  test "legacy model journals remain explicit across reset and resume", context do
    file = Path.join(context.cwd, "legacy.jsonl")

    context.cwd
    |> CodingAgent.SessionManager.new()
    |> CodingAgent.SessionManager.append_entry(
      CodingAgent.SessionManager.SessionEntry.model_change("openai", "gpt-4o")
    )
    |> CodingAgent.SessionManager.persist(file)

    first = session(context, session_file: file)
    assert turn(first, "hi").model == "gpt-4o"
    assert :ok = Session.reset(first)
    reset_state = Session.get_state(first)

    assert %{model_explicit: true} =
             CodingAgent.SessionManager.build_session_context(reset_state.session_manager)

    assert :ok = Session.save(first)
    :ok = GenServer.stop(first)

    resumed = session(context, session_file: reset_state.session_file)
    assert turn(resumed, "review").model == "gpt-4o"
  end

  test "unknown custom pricing cannot slip through a cap as zero", context do
    providers =
      Map.put(context.settings.providers, "local", %{
        api_key: "routing-local-key",
        api: "openai-completions",
        base_url: "http://unused.invalid/v1",
        models: [%{id: "partial-price", cost: %{input: 1, output: 1}}]
      })

    settings = %{
      context.settings
      | providers: providers,
        model_routing: %{
          "enabled" => true,
          "max_cost_usd" => 100,
          "rules" => [%{"model" => "local:partial-price"}]
        }
    }

    session = session(context, settings: settings)
    Session.subscribe(session)
    assert :ok = Session.prompt(session, "hi")
    assert_receive {:session_event, _, {:error, :model_routing_cost_cap, _}}, 5_000
    refute_receive {:provider_call, _, _, _}, 50
  end

  test "provider failover cannot bypass the selected model's cost cap", context do
    settings = %{
      context.settings
      | provider_routing: %{
          enabled: true,
          fallback_providers: [],
          fallback_models: ["openai:gpt-4o"],
          require_credentials: true
        },
        model_routing: %{
          "enabled" => true,
          "max_cost_usd" => 0.05,
          "rules" => [%{"model" => "openai:gpt-4o-mini"}]
        }
    }

    parent = self()

    stream_fn = fn model, _context, _options ->
      send(parent, {:fallback_attempt, model.id})
      {:error, {:http_error, 503, "unavailable"}}
    end

    {file, automatic, _prompt, _explicit} = branch_journal(context)
    session = session(context, settings: settings, stream_fn: stream_fn, session_file: file)
    restore(session, :navigate_tree, automatic, nil)
    Session.subscribe(session)
    assert :ok = Session.prompt(session, "hi")
    assert_receive {:fallback_attempt, "gpt-4o-mini"}, 5_000

    assert_receive {:session_event, _,
                    {:message_end, %AssistantMessage{stop_reason: :error} = rejection}},
                   5_000

    refute_receive {:fallback_attempt, "gpt-4o"}, 50
    assert rejection.model == "gpt-4o"
    assert rejection.error_details.provider_invoked == false
    assert CodingAgent.Executor.Usage.occurrence(rejection) == nil
  end

  for operation <- [:navigate_tree, :navigate_entry, :rewind] do
    @operation operation
    test "#{operation} preserves automatic rules and rejects unaffordable requests", context do
      operation = @operation
      {file, automatic, prompt, _explicit} = branch_journal(context)
      routed = session(context, session_file: file)
      restore(routed, operation, automatic, prompt)
      assert turn(routed, "hi").model == "gpt-4o-mini"
      assert_receive {:provider_call, :openai, "gpt-4o-mini", _}

      {file, automatic, prompt, _explicit} = branch_journal(context)

      settings = %{
        context.settings
        | model_routing: %{context.settings.model_routing | "max_cost_usd" => 0}
      }

      capped = session(context, settings: settings, session_file: file)
      restore(capped, operation, automatic, prompt)
      assert_automatic_cap(capped)
    end
  end

  test "navigating to root preserves the automatic cap", context do
    settings = %{
      context.settings
      | model_routing: %{context.settings.model_routing | "max_cost_usd" => 0}
    }

    session = session(context, settings: settings)
    assert :ok = Session.navigate_tree(session, :root)
    assert_automatic_cap(session)
  end

  for operation <- [:navigate_tree, :navigate_entry] do
    @operation operation
    test "#{operation} restores explicit bypass and can return to automatic cost checks",
         context do
      {file, automatic, _prompt, explicit} = branch_journal(context)

      settings = %{
        context.settings
        | model_routing: %{context.settings.model_routing | "max_cost_usd" => 0}
      }

      session = session(context, settings: settings, session_file: file)
      restore(session, @operation, explicit, nil)
      assert turn(session, "hi").model == "gpt-4o"
      assert_receive {:provider_call, :openai, "gpt-4o", _}
      restore(session, @operation, automatic, nil)
      assert_automatic_cap(session)
    end
  end

  defp branch_journal(context) do
    alias CodingAgent.SessionManager
    alias CodingAgent.SessionManager.SessionEntry

    file = Path.join(context.cwd, "branches-#{System.unique_integer([:positive])}.jsonl")

    automatic =
      context.cwd
      |> SessionManager.new()
      |> SessionManager.append_entry(
        SessionEntry.model_change("openai", "gpt-4o", explicit: false)
      )

    prompt = SessionManager.append_message(automatic, %{"role" => "user", "content" => "old"})

    explicit =
      prompt
      |> SessionManager.append_entry(
        SessionEntry.model_change("openai", "gpt-4o", explicit: true)
      )

    # Start on the explicit branch, exercising restoration in both directions
    # even when the concrete model is identical.
    SessionManager.persist(explicit, file)
    {file, automatic.leaf_id, prompt.leaf_id, explicit.leaf_id}
  end

  defp restore(session, :navigate_tree, entry, _prompt) do
    assert :ok = Session.navigate_tree(session, entry, summarize_abandoned: false)
  end

  defp restore(session, :navigate_entry, entry, _prompt) do
    assert {:ok, _} = Session.navigate_entry(session, entry)
  end

  defp restore(session, :rewind, _entry, prompt) do
    assert {:ok, preview} = Session.rewind(session, prompt)

    assert {:ok, _} =
             Session.rewind(session, prompt,
               dry_run: false,
               confirmation_token: preview["confirmationToken"]
             )
  end

  defp assert_automatic_cap(session) do
    assert :sys.get_state(Session.get_state(session).agent).model_routing
    Session.subscribe(session)
    assert :ok = Session.prompt(session, "hi")
    assert_receive {:session_event, _, {:error, :model_routing_cost_cap, _}}, 5_000
    refute_receive {:provider_call, _, _, _}, 50
  end

  defp session(context, overrides \\ []) do
    test_pid = self()
    settings = Keyword.get(overrides, :settings, context.settings)

    stream_fn = fn model, _context, options ->
      send(test_pid, {:provider_call, model.provider, model.id, options.api_key})

      response = %AssistantMessage{
        content: [%TextContent{text: "done"}],
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

    opts = [
      cwd: context.cwd,
      workspace_dir: Path.join(context.cwd, "workspace"),
      session_file: Path.join(context.cwd, "#{System.unique_integer([:positive])}.jsonl"),
      settings_manager: settings,
      system_prompt: "test routing",
      tools: [],
      stream_fn: stream_fn,
      register: false
    ]

    opts = Keyword.merge(opts, Keyword.delete(overrides, :settings))
    file = Keyword.fetch!(opts, :session_file)

    unless File.exists?(file) do
      context.cwd
      |> CodingAgent.SessionManager.new()
      |> CodingAgent.SessionManager.persist(file)
    end

    spec =
      Supervisor.child_spec(
        {Session, opts},
        id: make_ref(),
        restart: :temporary
      )

    start_supervised!(spec)
  end

  defp turn(session, prompt) do
    Session.subscribe(session)
    assert :ok = Session.prompt(session, prompt)
    assert_receive {:session_event, id, {:message_end, %AssistantMessage{} = response}}, 5_000
    assert_receive {:session_event, ^id, {:agent_end, _}}, 5_000
    response
  end
end
