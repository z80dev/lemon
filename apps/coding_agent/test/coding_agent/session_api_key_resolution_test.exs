defmodule CodingAgent.SessionApiKeyResolutionTest do
  use ExUnit.Case, async: false

  alias Ai.Types.{AssistantMessage, Cost, Model, ModelCost, TextContent, Usage}
  alias CodingAgent.{Session, SettingsManager}
  alias LemonCore.{Secrets, Store}

  setup do
    clear_secrets_table()

    master_key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    System.put_env("LEMON_SECRETS_MASTER_KEY", master_key)
    System.delete_env("OPENAI_API_KEY")
    System.delete_env("OPENAI_CODEX_API_KEY")
    System.delete_env("CHATGPT_TOKEN")
    System.delete_env("ANTHROPIC_API_KEY")
    System.delete_env("OPENCODE_API_KEY")
    System.delete_env("GITHUB_COPILOT_API_KEY")
    System.delete_env("ANTHROPIC_API_KEY")
    System.delete_env("OPENAI_CODEX_API_KEY")
    System.delete_env("CHATGPT_TOKEN")

    on_exit(fn ->
      clear_secrets_table()
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
      System.delete_env("OPENAI_API_KEY")
      System.delete_env("OPENAI_CODEX_API_KEY")
      System.delete_env("CHATGPT_TOKEN")
      System.delete_env("ANTHROPIC_API_KEY")
      System.delete_env("OPENCODE_API_KEY")
      System.delete_env("GITHUB_COPILOT_API_KEY")
      System.delete_env("ANTHROPIC_API_KEY")
      System.delete_env("OPENAI_CODEX_API_KEY")
      System.delete_env("CHATGPT_TOKEN")
    end)

    :ok
  end

  test "env key overrides plain and secret-backed provider keys" do
    assert {:ok, _} = Secrets.set("llm_openai_api_key", "from-secret")
    System.put_env("OPENAI_API_KEY", "from-env")

    settings =
      settings(%{
        "openai" => %{api_key: "from-plain", api_key_secret: "llm_openai_api_key"}
      })

    session = start_session(self(), settings)
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "from-env"}, 1_000
    GenServer.stop(session)
  end

  test "plain provider api_key overrides api_key_secret" do
    assert {:ok, _} = Secrets.set("llm_openai_api_key", "from-secret")

    settings =
      settings(%{
        "openai" => %{api_key: "from-plain", api_key_secret: "llm_openai_api_key"}
      })

    session = start_session(self(), settings)
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "from-plain"}, 1_000
    GenServer.stop(session)
  end

  test "opencode env key overrides plain and secret-backed provider keys" do
    assert {:ok, _} = Secrets.set("llm_opencode_api_key", "from-secret")
    System.put_env("OPENCODE_API_KEY", "from-env")

    settings =
      settings(%{
        "opencode" => %{api_key: "from-plain", api_key_secret: "llm_opencode_api_key"}
      })

    session = start_session(self(), settings, mock_model(:opencode))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "from-env"}, 1_000
    GenServer.stop(session)
  end

  test "api_key_secret is used when env and plain key are missing" do
    assert {:ok, _} = Secrets.set("llm_openai_api_key", "from-secret")

    settings =
      settings(%{
        "openai" => %{api_key_secret: "llm_openai_api_key"}
      })

    session = start_session(self(), settings)
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "from-secret"}, 1_000
    GenServer.stop(session)
  end

  test "default provider secret mapping is used when api_key_secret is absent" do
    assert {:ok, _} = Secrets.set("llm_openai_api_key", "from-default-secret")

    settings =
      settings(%{
        "openai" => %{}
      })

    session = start_session(self(), settings)
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "from-default-secret"}, 1_000
    GenServer.stop(session)
  end

  test "openai-codex oauth source resolves OAuth secret payload and ignores env/plain api key" do
    oauth_secret =
      Jason.encode!(%{
        "type" => "onboarding_openai_codex_oauth",
        "access_token" => "codex-access-token",
        "refresh_token" => "codex-refresh-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
      })

    assert {:ok, _} = Secrets.set("llm_openai_codex_api_key", oauth_secret)
    System.put_env("OPENAI_CODEX_API_KEY", "codex-from-env")
    System.put_env("CHATGPT_TOKEN", "chatgpt-from-env")

    settings =
      settings(%{
        "openai-codex" => %{
          auth_source: "oauth",
          api_key: "codex-from-plain",
          api_key_secret: "llm_openai_codex_api_key"
        }
      })

    session = start_session(self(), settings, mock_model(:"openai-codex"))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "codex-access-token"}, 1_000
    GenServer.stop(session)
  end

  test "openai-codex api_key source resolves env/plain key and does not use oauth payload secret by default" do
    oauth_secret =
      Jason.encode!(%{
        "type" => "onboarding_openai_codex_oauth",
        "access_token" => "codex-oauth-token",
        "refresh_token" => "codex-refresh-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
      })

    assert {:ok, _} = Secrets.set("llm_openai_codex_api_key", oauth_secret)
    System.put_env("OPENAI_CODEX_API_KEY", "codex-from-env")

    settings =
      settings(%{
        "openai-codex" => %{auth_source: "api_key", api_key: "codex-from-plain"}
      })

    session = start_session(self(), settings, mock_model(:"openai-codex"))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "codex-from-env"}, 1_000
    GenServer.stop(session)
  end

  test "openai-codex requires auth_source" do
    settings =
      settings(%{
        "openai-codex" => %{api_key: "codex-from-plain"}
      })

    session = start_session(self(), settings, mock_model(:"openai-codex"))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, ""}, 1_000
    GenServer.stop(session)
  end

  test "anthropic rejects oauth auth_source even when env key exists" do
    assert {:ok, _} = Secrets.set("llm_anthropic_api_key", "anthropic-from-secret")
    System.put_env("ANTHROPIC_API_KEY", "anthropic-from-env")

    settings =
      settings(%{
        "anthropic" => %{
          auth_source: "oauth",
          api_key: "anthropic-from-plain",
          api_key_secret: "llm_anthropic_api_key"
        }
      })

    session = start_session(self(), settings, mock_model(:anthropic))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, ""}, 1_000
    GenServer.stop(session)
  end

  test "anthropic api_key_secret is used when env and plain key are missing" do
    assert {:ok, _} = Secrets.set("llm_anthropic_api_key_raw", "anthropic-from-secret")

    settings =
      settings(%{
        "anthropic" => %{api_key_secret: "llm_anthropic_api_key_raw"}
      })

    session = start_session(self(), settings, mock_model(:anthropic))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "anthropic-from-secret"}, 1_000
    GenServer.stop(session)
  end

  test "anthropic falls back to llm_anthropic_api_key_raw when api_key_secret is absent" do
    assert {:ok, _} = Secrets.set("llm_anthropic_api_key_raw", "anthropic-from-default-secret")

    settings =
      settings(%{
        "anthropic" => %{}
      })

    session = start_session(self(), settings, mock_model(:anthropic))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "anthropic-from-default-secret"}, 1_000
    GenServer.stop(session)
  end

  test "github copilot oauth secret resolves to access token" do
    oauth_secret =
      Jason.encode!(%{
        "type" => "github_copilot_oauth",
        "refresh_token" => "github-refresh-token",
        "access_token" => "copilot-access-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "enterprise_domain" => nil,
        "base_url" => "https://api.individual.githubcopilot.com",
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, _} = Secrets.set("llm_github_copilot_api_key", oauth_secret)

    settings =
      settings(%{
        "github_copilot" => %{api_key_secret: "llm_github_copilot_api_key"}
      })

    session = start_session(self(), settings, mock_model(:github_copilot))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "copilot-access-token"}, 1_000
    GenServer.stop(session)
  end

  test "github copilot env key overrides oauth secret" do
    oauth_secret =
      Jason.encode!(%{
        "type" => "github_copilot_oauth",
        "refresh_token" => "github-refresh-token",
        "access_token" => "copilot-access-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
      })

    assert {:ok, _} = Secrets.set("llm_github_copilot_api_key", oauth_secret)
    System.put_env("GITHUB_COPILOT_API_KEY", "copilot-from-env")

    settings =
      settings(%{
        "github_copilot" => %{api_key_secret: "llm_github_copilot_api_key"}
      })

    session = start_session(self(), settings, mock_model(:github_copilot))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "copilot-from-env"}, 1_000
    GenServer.stop(session)
  end

  test "falls back to provider-specific oauth resolvers when oauth dispatcher module is unavailable" do
    Application.put_env(
      :coding_agent,
      :oauth_secret_resolver_module,
      Ai.Auth.MissingOAuthSecretResolver
    )

    on_exit(fn ->
      Application.delete_env(:coding_agent, :oauth_secret_resolver_module)
    end)

    oauth_secret =
      Jason.encode!(%{
        "type" => "github_copilot_oauth",
        "refresh_token" => "github-refresh-token",
        "access_token" => "copilot-access-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "enterprise_domain" => nil,
        "base_url" => "https://api.individual.githubcopilot.com",
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, _} = Secrets.set("llm_github_copilot_api_key", oauth_secret)

    settings =
      settings(%{
        "github_copilot" => %{api_key_secret: "llm_github_copilot_api_key"}
      })

    session = start_session(self(), settings, mock_model(:github_copilot))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "copilot-access-token"}, 1_000
    GenServer.stop(session)
  end

  test "anthropic oauth payload secret is rejected for provider api-key resolution" do
    oauth_secret =
      Jason.encode!(%{
        "type" => "anthropic_oauth",
        "refresh_token" => "anthropic-refresh-token",
        "access_token" => "anthropic-access-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, _} = Secrets.set("llm_anthropic_api_key", oauth_secret)

    settings =
      settings(%{
        "anthropic" => %{api_key_secret: "llm_anthropic_api_key"}
      })

    session = start_session(self(), settings, mock_model(:anthropic))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, ""}, 1_000
    GenServer.stop(session)
  end

  test "google antigravity oauth secret resolves to json token+projectId" do
    oauth_secret =
      Jason.encode!(%{
        "type" => "google_antigravity_oauth",
        "refresh_token" => "google-refresh-token",
        "access_token" => "google-access-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "project_id" => "proj-123",
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, _} = Secrets.set("llm_google_antigravity_api_key", oauth_secret)

    settings =
      settings(%{
        "google_antigravity" => %{api_key_secret: "llm_google_antigravity_api_key"}
      })

    session = start_session(self(), settings, mock_model(:google_antigravity))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, resolved_key}, 1_000
    assert {:ok, decoded} = Jason.decode(resolved_key)
    assert decoded["token"] == "google-access-token"
    assert decoded["projectId"] == "proj-123"

    GenServer.stop(session)
  end

  test "openai codex oauth secret resolves to access token" do
    oauth_secret =
      Jason.encode!(%{
        "type" => "openai_codex_oauth",
        "refresh_token" => "codex-refresh-token",
        "access_token" => "codex-access-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "account_id" => "acc-123",
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, _} = Secrets.set("llm_openai_codex_api_key", oauth_secret)

    settings =
      settings(%{
        "openai-codex" => %{auth_source: "oauth", api_key_secret: "llm_openai_codex_api_key"}
      })

    session = start_session(self(), settings, mock_model(:"openai-codex"))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "codex-access-token"}, 1_000
    GenServer.stop(session)
  end

  test "openai codex env key overrides api_key_secret when auth_source is api_key" do
    oauth_secret =
      Jason.encode!(%{
        "type" => "openai_codex_oauth",
        "refresh_token" => "codex-refresh-token",
        "access_token" => "codex-access-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "account_id" => "acc-123",
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, _} = Secrets.set("llm_openai_codex_api_key", oauth_secret)
    System.put_env("OPENAI_CODEX_API_KEY", "codex-from-env")

    settings =
      settings(%{
        "openai-codex" => %{auth_source: "api_key", api_key_secret: "llm_openai_codex_api_key"}
      })

    session = start_session(self(), settings, mock_model(:"openai-codex"))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "codex-from-env"}, 1_000
    GenServer.stop(session)
  end

  defp settings(providers) do
    %SettingsManager{
      default_thinking_level: :medium,
      providers: providers,
      tools: %{wasm: %{enabled: false}}
    }
  end

  defp start_session(test_pid, settings_manager, model \\ mock_model()) do
    {:ok, session} =
      Session.start_link(
        cwd: System.tmp_dir!(),
        model: model,
        settings_manager: settings_manager,
        stream_fn: stream_fn(test_pid)
      )

    session
  end

  defp stream_fn(test_pid) do
    fn _model, _context, options ->
      send(test_pid, {:stream_api_key, options.api_key})
      {:ok, response_stream()}
    end
  end

  defp response_stream do
    response = assistant_message("ok")
    {:ok, stream} = Ai.EventStream.start_link()

    Task.start(fn ->
      Ai.EventStream.push(stream, {:start, response})
      Ai.EventStream.push(stream, {:done, response.stop_reason, response})
      Ai.EventStream.complete(stream, response)
    end)

    stream
  end

  defp mock_model(provider \\ :openai) do
    %Model{
      id: "mock-#{provider}-model",
      name: "Mock #{provider}",
      api: :mock,
      provider: provider,
      base_url: "https://api.mock.test",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.01, output: 0.03},
      context_window: 128_000,
      max_tokens: 4096,
      headers: %{},
      compat: nil
    }
  end

  defp assistant_message(text) do
    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: text}],
      api: :mock,
      provider: :openai,
      model: "mock-openai-model",
      usage: mock_usage(),
      stop_reason: :stop,
      error_message: nil,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp mock_usage do
    %Usage{
      input: 10,
      output: 5,
      cache_read: 0,
      cache_write: 0,
      total_tokens: 15,
      cost: %Cost{input: 0.0001, output: 0.0002, total: 0.0003}
    }
  end

  defp clear_secrets_table do
    Store.list(Secrets.table())
    |> Enum.each(fn {key, _value} ->
      Store.delete(Secrets.table(), key)
    end)
  end
end
