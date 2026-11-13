defmodule CodingAgent.Session.ModelRolesTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Session
  alias CodingAgent.Session.ModelResolver
  alias CodingAgent.SettingsManager
  alias CodingAgent.Tools.Task.Params

  defmodule ChildRoleProvider do
    def stream(model, _context, options) do
      text = "#{model.id}|#{options.api_key}"

      response = %LemonAi.Types.AssistantMessage{
        content: [%LemonAi.Types.TextContent{text: text}],
        stop_reason: :stop,
        model: model.id,
        provider: model.provider
      }

      {:ok, stream} = LemonAi.EventStream.start_link()
      LemonAi.EventStream.push(stream, {:start, response})
      LemonAi.EventStream.push(stream, {:text_start, 0, response})
      LemonAi.EventStream.push(stream, {:text_delta, 0, text, response})
      LemonAi.EventStream.push(stream, {:text_end, 0, response})
      LemonAi.EventStream.push(stream, {:done, :stop, response})
      LemonAi.EventStream.complete(stream, response)
      {:ok, stream}
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "native_model_roles_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    saved_home = System.get_env("HOME")
    saved_paths = Application.get_env(:lemon_core, :paths)
    System.put_env("HOME", root)
    Application.put_env(:lemon_core, :paths, home_dir: root)

    on_exit(fn ->
      if saved_home, do: System.put_env("HOME", saved_home), else: System.delete_env("HOME")

      if saved_paths,
        do: Application.put_env(:lemon_core, :paths, saved_paths),
        else: Application.delete_env(:lemon_core, :paths)

      File.rm_rf!(root)
    end)

    settings = %SettingsManager{
      default_model: %{provider: :openai, model_id: "gpt-4", base_url: nil},
      providers: %{"openai" => %{api_key: "synthetic-openai-key"}},
      provider_routing: %{enabled: false}
    }

    %{cwd: root, settings: settings}
  end

  test "native sessions accept default, smol and slow selectors", %{cwd: cwd, settings: settings} do
    settings = %{
      settings
      | model_roles: %{
          "default" => "@slow",
          "slow" => "openai:gpt-4",
          "smol" => "openai:gpt-4o-mini"
        }
    }

    for {selector, id} <- [{"@default", "gpt-4"}, {"@smol", "gpt-4o-mini"}, {"@slow", "gpt-4"}] do
      session =
        start_supervised!(
          {Session, [cwd: cwd, model: selector, settings_manager: settings, register: false]},
          id: make_ref()
        )

      state = Session.get_state(session)
      assert state.model.provider == :openai
      assert state.model.id == id
    end
  end

  test "canonical default may be @default without recursive default resolution", %{cwd: cwd} do
    config = %LemonCore.Config{
      agent: %{
        default_provider: "openai",
        default_model: "@default",
        provider_routing: %{enabled: false}
      },
      model_roles: %{"default" => "@slow", "slow" => "openai:gpt-4"},
      providers: %{"openai" => %{api_key: "synthetic-openai-key"}}
    }

    settings = SettingsManager.from_config(config)
    assert settings.default_model == "@default"
    assert settings.model_roles == config.model_roles
    assert SettingsManager.get_model_settings(settings).model_roles == config.model_roles

    session =
      start_supervised!({Session, [cwd: cwd, settings_manager: settings, register: false]})

    assert Session.get_state(session).model.id == "gpt-4"
  end

  test "unconfigured built-ins preserve the configured concrete default", %{settings: settings} do
    expected = ModelResolver.resolve_session_model(nil, settings)

    for selector <- ~w(@default @smol @slow) do
      assert ModelResolver.resolve_session_model(selector, settings) == expected
    end
  end

  test "unknown, cyclic and invalid overrides fail clearly", %{settings: settings} do
    assert_raise ArgumentError, ~r/unknown model role @missing/, fn ->
      ModelResolver.resolve_session_model("@missing", settings)
    end

    assert_raise ArgumentError, ~r/model role cycle/, fn ->
      ModelResolver.resolve_session_model("@smol", %{
        settings
        | model_roles: %{"smol" => "@slow", "slow" => "@smol"}
      })
    end

    assert_raise ArgumentError, ~r/model_roles.smol/, fn ->
      SettingsManager.from_config(%LemonCore.Config{model_roles: %{"smol" => 42}})
    end

    assert_raise ArgumentError, ~r/unknown model/, fn ->
      ModelResolver.resolve_session_model("@smol", %{
        settings
        | model_roles: %{"smol" => "unknown-provider:unknown-model"}
      })
    end
  end

  test "task selectors expand centrally and omission keeps parent inheritance", %{
    cwd: cwd,
    settings: settings
  } do
    parent = ModelResolver.resolve_session_model("openai:gpt-4", settings)
    settings = %{settings | model_roles: %{"smol" => "openai:gpt-4o-mini", "slow" => "@default"}}
    opts = [settings_manager: settings, model: parent]
    assert Params.build_session_opts(cwd, opts, %{})[:model] == parent
    assert Params.build_session_opts(cwd, opts, %{model: "@smol"})[:model].id == "gpt-4o-mini"
    assert Params.build_session_opts(cwd, opts, %{model: "@slow"})[:model] == parent

    assert Params.build_session_opts(cwd, opts, %{model: "openai:gpt-4o"})[:model] ==
             "openai:gpt-4o"

    task_settings = %{settings | model_roles: Map.put(settings.model_roles, "task", "@smol")}
    task_opts = Keyword.put(opts, :settings_manager, task_settings)
    assert Params.build_session_opts(cwd, task_opts, %{})[:model].id == "gpt-4o-mini"
    assert Params.build_session_opts(cwd, task_opts, %{model: "@slow"})[:model] == parent

    assert_raise ArgumentError, ~r/unknown model role @missing/, fn ->
      Params.build_session_opts(cwd, task_opts, %{model: "@missing"})
    end
  end

  test "task model is inherited from the actual native parent state", %{
    cwd: cwd,
    settings: settings
  } do
    parent =
      start_supervised!(
        {Session, [cwd: cwd, model: "openai:gpt-4o", settings_manager: settings, register: false]}
      )

    opts = [settings_manager: settings, session_pid: parent]
    expected = Session.get_state(parent).model
    assert Params.build_session_opts(cwd, opts, %{})[:model] == expected
    assert Params.build_session_opts(cwd, opts, %{model: "@smol"})[:model] == expected
  end

  test "sync and async task executions stream with the selected child model", %{
    cwd: cwd,
    settings: settings
  } do
    parent_model = ModelResolver.resolve_session_model("openai:gpt-4o", settings)

    configured = %{
      settings
      | model_roles: %{
          "task" => "@smol",
          "smol" => "openai:gpt-4o-mini",
          "slow" => "openai:gpt-4"
        }
    }

    test_pid = self()

    for async? <- [false, true],
        {task_settings, selector, expected_id} <- [
          {configured, nil, "gpt-4o-mini"},
          {configured, "@slow", "gpt-4"},
          {settings, nil, "gpt-4o"},
          {settings, "@smol", "gpt-4o"}
        ] do
      tag = make_ref()

      stream_fn = fn model, _context, options ->
        send(test_pid, {:child_model, tag, model.id, options.api_key})

        response = %LemonAi.Types.AssistantMessage{
          content: [%LemonAi.Types.TextContent{text: "Selected child completed"}],
          stop_reason: :stop,
          model: model.id,
          provider: model.provider
        }

        {:ok, stream} = LemonAi.EventStream.start_link()
        LemonAi.EventStream.push(stream, {:start, response})
        LemonAi.EventStream.push(stream, {:text_start, 0, response})
        LemonAi.EventStream.push(stream, {:text_delta, 0, "Selected child completed", response})
        LemonAi.EventStream.push(stream, {:text_end, 0, response})
        LemonAi.EventStream.push(stream, {:done, :stop, response})
        LemonAi.EventStream.complete(stream, response)
        {:ok, stream}
      end

      params = %{
        "prompt" => "Complete the focused task.",
        "async" => async?,
        "auto_followup" => false
      }

      params = if selector, do: Map.put(params, "model", selector), else: params

      result =
        CodingAgent.Tools.Task.execute("role_task", params, nil, nil, cwd,
          model: parent_model,
          # Explicit child selectors are per-call selections; the operator enables them.
          settings_manager: %{
            task_settings
            | task: %{task_settings.task | per_call_model: "on"}
          },
          stream_fn: stream_fn,
          task_session_timeout_ms: 5_000
        )

      assert %LemonAgent.Types.AgentToolResult{} = result
      assert_receive {:child_model, ^tag, ^expected_id, "synthetic-openai-key"}, 5_000

      if async? do
        joined =
          CodingAgent.Tools.Task.execute(
            "role_join",
            %{"action" => "join", "task_id" => result.details.task_id},
            nil,
            nil,
            cwd,
            []
          )

        assert %LemonAgent.Types.AgentToolResult{} = joined

        assert {:ok, %{status: :completed}, _events} =
                 CodingAgent.TaskStore.get(result.details.task_id)
      else
        assert result.details.status == "completed"
      end
    end
  end

  test "direct coordinator children honor task defaults without changing unconfigured inheritance",
       %{cwd: cwd, settings: settings} do
    parent_model = ModelResolver.resolve_session_model("openai:gpt-4o", settings)
    selected_model = ModelResolver.resolve_session_model("openai:gpt-4o-mini", settings)
    apis = Enum.uniq([parent_model.api, selected_model.api])
    previous = Map.new(apis, &{&1, LemonAi.ProviderRegistry.get(&1)})
    Enum.each(apis, &LemonAi.ProviderRegistry.register(&1, ChildRoleProvider))

    on_exit(fn ->
      Enum.each(previous, fn
        {api, {:ok, module}} -> LemonAi.ProviderRegistry.register(api, module)
        {api, {:error, :not_found}} -> LemonAi.ProviderRegistry.unregister(api)
      end)
    end)

    configured = %{settings | model_roles: %{"task" => "@smol", "smol" => "openai:gpt-4o-mini"}}

    for {task_settings, expected_id} <- [{settings, "gpt-4o"}, {configured, "gpt-4o-mini"}] do
      coordinator =
        start_supervised!(
          {CodingAgent.Coordinator,
           [
             cwd: cwd,
             model: parent_model,
             settings_manager: task_settings,
             default_timeout: 5_000
           ]},
          id: make_ref()
        )

      assert {:ok, text} =
               CodingAgent.Coordinator.run_subagent(coordinator,
                 prompt: "Complete the focused task.",
                 timeout: 5_000
               )

      assert text == expected_id <> "|synthetic-openai-key"
    end
  end
end
