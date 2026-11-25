defmodule CodingAgent.Session.CompactionModelRolesTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Compaction
  alias CodingAgent.Session.{CompactionManager, ModelResolver}
  alias CodingAgent.SessionManager
  alias CodingAgent.SettingsManager

  defmodule SummaryProvider do
    def stream(model, _context, opts) do
      response = %LemonAi.Types.AssistantMessage{
        content: [
          %LemonAi.Types.TextContent{
            text:
              inspect(
                {model.provider, model.id, opts.api_key, opts.headers,
                 opts.provider_options[:azure_openai_responses]}
              )
          }
        ],
        stop_reason: :stop
      }

      {:ok, stream} = LemonAi.EventStream.start_link()
      LemonAi.EventStream.complete(stream, response)
      {:ok, stream}
    end
  end

  setup_all do
    LemonAi.ProviderRegistry.register(:compaction_model_roles_test, SummaryProvider)
    on_exit(fn -> LemonAi.ProviderRegistry.unregister(:compaction_model_roles_test) end)
    :ok
  end

  setup do
    settings = %SettingsManager{
      default_model: %{provider: :openai, model_id: "gpt-4", base_url: nil},
      providers: %{
        "openai" => %{api_key: "synthetic-main-key"},
        "azure_openai_responses" => %{
          api_key: "synthetic-summary-key",
          base_url: "https://synthetic-azure.invalid",
          api_version: "synthetic-version"
        }
      },
      provider_routing: %{enabled: false}
    }

    model = ModelResolver.resolve_session_model("openai:gpt-4o", settings)
    %{state: %{model: model, settings_manager: settings, cwd: System.tmp_dir!()}}
  end

  test "configured compaction wins over smol and resolves the selected credentials/options", %{
    state: state
  } do
    settings = %{
      state.settings_manager
      | model_roles: %{
          "compaction" => "@summary",
          "summary" => "azure_openai_responses:gpt-4",
          "smol" => "openai:gpt-4o-mini"
        }
    }

    state = %{state | settings_manager: settings}
    opts = CompactionManager.summary_options([], state)
    assert opts[:model].provider == :azure_openai_responses
    assert opts[:model].id == "gpt-4"
    assert opts[:api_key] == "synthetic-summary-key"
    assert opts[:stream_options].api_key == "synthetic-summary-key"

    azure = opts[:stream_options].provider_options.azure_openai_responses
    assert azure.base_url == "https://synthetic-azure.invalid"
    assert azure.api_version == "synthetic-version"
    assert state.model.provider == :openai
    assert state.model.id == "gpt-4o"
  end

  test "configured smol is used only when present, otherwise the active model is retained", %{
    state: state
  } do
    smol_state = %{
      state
      | settings_manager: %{
          state.settings_manager
          | model_roles: %{"smol" => "azure_openai_responses:gpt-4"}
        }
    }

    assert CompactionManager.summary_options([], smol_state)[:api_key] == "synthetic-summary-key"

    default_state = %{
      state
      | settings_manager: %{
          state.settings_manager
          | model_roles: %{"default" => "azure_openai_responses:gpt-4"}
        }
    }

    opts = CompactionManager.summary_options([], default_state)
    assert opts[:model] == state.model
    assert opts[:api_key] == "synthetic-main-key"

    fallback_state = %{
      state
      | settings_manager: %{state.settings_manager | model_roles: %{"compaction" => "@smol"}}
    }

    assert CompactionManager.summary_options([], fallback_state)[:model] == state.model
  end

  test "explicit model, credential and stream option overrides retain precedence", %{state: state} do
    state = %{
      state
      | settings_manager: %{
          state.settings_manager
          | model_roles: %{"compaction" => "azure_openai_responses:gpt-4"}
        }
    }

    opts =
      CompactionManager.summary_options(
        [
          model: "openai:gpt-4o-mini",
          api_key: "explicit-key",
          stream_options: %{headers: %{"x-summary" => "present"}, api_key: "stream-key"}
        ],
        state
      )

    assert opts[:model].provider == :openai
    assert opts[:model].id == "gpt-4o-mini"
    assert opts[:api_key] == "explicit-key"
    assert opts[:stream_options].api_key == "explicit-key"
    assert opts[:stream_options].headers["x-summary"] == "present"

    stream_opts =
      CompactionManager.summary_options(
        [model: "openai:gpt-4", stream_options: %{api_key: "stream-key"}],
        state
      )

    assert stream_opts[:api_key] == "stream-key"
  end

  test "bad compaction overrides do not fall back to smol or the active model", %{state: state} do
    for roles <- [
          %{"compaction" => "@missing", "smol" => "openai:gpt-4"},
          %{"compaction" => "@compaction"},
          %{"smol" => ""}
        ] do
      state = %{state | settings_manager: %{state.settings_manager | model_roles: roles}}
      assert_raise ArgumentError, fn -> CompactionManager.summary_options([], state) end
    end
  end

  test "ordinary, branch and background summaries use the selected model and credentials together",
       %{state: state} do
    state = %{
      state
      | settings_manager: %{
          state.settings_manager
          | model_roles: %{"compaction" => "azure_openai_responses:gpt-4"}
        }
    }

    opts =
      CompactionManager.summary_options(
        [stream_options: %{headers: %{"x-summary" => "present"}}],
        state
      )

    # Dispatch the selected model through a deterministic provider, never a real API.
    selected = %{opts[:model] | api: :compaction_model_roles_test}
    opts = Keyword.put(opts, :model, selected)
    unused_active = %{state.model | api: :unused_compaction_active_api}
    messages = [%LemonAi.Types.UserMessage{content: "Summarize the selected provider"}]

    assert {:ok, summary} = Compaction.generate_summary(messages, unused_active, opts)
    assert_selected_summary(summary)

    session =
      Enum.reduce(1..8, SessionManager.new(System.tmp_dir!()), fn n, session ->
        SessionManager.append_message(session, %{"role" => "user", "content" => "Message #{n}"})
      end)

    assert {:ok, branch_summary} =
             Compaction.generate_branch_summary(
               SessionManager.get_branch(session),
               unused_active,
               opts
             )

    assert_selected_summary(branch_summary)

    opts =
      opts
      |> Keyword.put(:force, true)
      |> Keyword.put(:keep_recent_tokens, 1)
      |> Keyword.put(:min_keep_messages, 2)

    assert {:ok, result} =
             CompactionManager.auto_compaction_task_result(session, unused_active, opts)

    assert_selected_summary(result.summary)
  end

  defp assert_selected_summary(summary) do
    assert summary =~ "azure_openai_responses"
    assert summary =~ "gpt-4"
    assert summary =~ "synthetic-summary-key"
    assert summary =~ "x-summary"
    assert summary =~ "synthetic-azure.invalid"
    refute summary =~ "synthetic-main-key"
  end
end
