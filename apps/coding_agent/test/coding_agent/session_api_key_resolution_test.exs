defmodule CodingAgent.SessionApiKeyResolutionTest do
  use ExUnit.Case, async: false

  alias LemonAi.Types.{AssistantMessage, Cost, Model, ModelCost, TextContent, Usage}
  alias CodingAgent.{Session, SettingsManager}
  alias LemonCore.{Secrets, Store}
  alias LemonAgent.ModelRuntime.CredentialHealth

  # Loopback provider endpoint for the public-session wire cases: records every
  # request (method, path, headers, body) to the test process.
  defmodule WireEndpoint do
    @moduledoc false
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        opts[:test_pid],
        {:wire, conn.method, conn.request_path, Map.new(conn.req_headers), body}
      )

      # Any request reaching this listener has already failed the test; a
      # non-retryable auth rejection keeps the session's terminal bounded.
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        401,
        Jason.encode!(%{
          "error" => %{"type" => "authentication_error", "message" => "wire trap"}
        })
      )
    end
  end

  setup do
    clear_secrets_table()

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "coding_agent_session_api_key_resolution_#{System.unique_integer([:positive])}"
      )

    home_dir = Path.join(tmp_dir, "home")
    File.mkdir_p!(home_dir)
    # Session init scans its cwd; System.tmp_dir!() can be arbitrarily large.
    session_cwd = Path.join(tmp_dir, "cwd")
    File.mkdir_p!(session_cwd)
    Process.put(:session_cwd, session_cwd)

    master_key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    original_home = System.get_env("HOME")
    System.put_env("LEMON_SECRETS_MASTER_KEY", master_key)
    System.put_env("HOME", home_dir)
    System.delete_env("OPENAI_API_KEY")
    System.delete_env("OPENAI_CODEX_API_KEY")
    System.delete_env("CHATGPT_TOKEN")
    System.delete_env("ANTHROPIC_API_KEY")
    System.delete_env("ANTHROPIC_TOKEN")
    System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")
    System.delete_env("OPENCODE_API_KEY")
    System.delete_env("GITHUB_COPILOT_API_KEY")
    System.delete_env("GOOGLE_GEMINI_CLI_API_KEY")
    System.delete_env("LEMON_GEMINI_PROJECT_ID")
    System.delete_env("GOOGLE_CLOUD_PROJECT")
    System.delete_env("GOOGLE_CLOUD_PROJECT_ID")
    System.delete_env("GCLOUD_PROJECT")
    System.delete_env("ANTHROPIC_API_KEY")
    System.delete_env("OPENAI_CODEX_API_KEY")
    System.delete_env("CHATGPT_TOKEN")

    on_exit(fn ->
      clear_secrets_table()
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")
      System.delete_env("OPENAI_API_KEY")
      System.delete_env("OPENAI_CODEX_API_KEY")
      System.delete_env("CHATGPT_TOKEN")
      System.delete_env("ANTHROPIC_API_KEY")
      System.delete_env("ANTHROPIC_TOKEN")
      System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")
      System.delete_env("OPENCODE_API_KEY")
      System.delete_env("GITHUB_COPILOT_API_KEY")
      System.delete_env("GOOGLE_GEMINI_CLI_API_KEY")
      System.delete_env("LEMON_GEMINI_PROJECT_ID")
      System.delete_env("GOOGLE_CLOUD_PROJECT")
      System.delete_env("GOOGLE_CLOUD_PROJECT_ID")
      System.delete_env("GCLOUD_PROJECT")
      System.delete_env("ANTHROPIC_API_KEY")
      System.delete_env("OPENAI_CODEX_API_KEY")
      System.delete_env("CHATGPT_TOKEN")
      File.rm_rf!(tmp_dir)
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
    System.put_env("OPENAI_CODEX_API_KEY", "codex-from-env")
    System.put_env("CHATGPT_TOKEN", "chatgpt-from-env")

    settings =
      settings(%{
        "openai-codex" => %{api_key: "codex-from-plain"}
      })

    session = start_session(self(), settings, mock_model(:"openai-codex"))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, ""}, 1_000
    GenServer.stop(session)
  end

  test "anthropic oauth auth_source resolves oauth payload secret and ignores raw api key env" do
    oauth_secret =
      Jason.encode!(%{
        "type" => "anthropic_oauth",
        "refresh_token" => "anthropic-refresh-token",
        "access_token" => "sk-ant-oat01-secret-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, _} = Secrets.set("llm_anthropic_api_key", oauth_secret)
    System.put_env("ANTHROPIC_API_KEY", "anthropic-from-env")

    settings =
      settings(%{
        "anthropic" => %{
          auth_source: "oauth",
          api_key: "anthropic-from-plain",
          oauth_secret: "llm_anthropic_api_key"
        }
      })

    session = start_session(self(), settings, mock_model(:anthropic))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "sk-ant-oat01-secret-token"}, 1_000
    GenServer.stop(session)
  end

  test "anthropic oauth auth_source resolves ambient Claude token env" do
    System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-env-token")

    settings =
      settings(%{
        "anthropic" => %{
          auth_source: "oauth"
        }
      })

    session = start_session(self(), settings, mock_model(:anthropic))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "sk-ant-oat01-env-token"}, 1_000
    GenServer.stop(session)
  end

  test "anthropic oauth auth_source prefers refreshable Claude credentials over static env token" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "coding_agent_anthropic_oauth_#{System.unique_integer([:positive])}"
      )

    home_dir = Path.join(tmp_dir, "home")
    credentials_path = Path.join([home_dir, ".claude", ".credentials.json"])
    original_home = System.get_env("HOME")

    File.mkdir_p!(Path.dirname(credentials_path))

    File.write!(
      credentials_path,
      Jason.encode!(%{
        "claudeAiOauth" => %{
          "accessToken" => "sk-ant-oat01-refreshable-token",
          "refreshToken" => "refresh-token",
          "expiresAt" => System.system_time(:millisecond) + 3_600_000
        }
      })
    )

    System.put_env("HOME", home_dir)
    System.put_env("ANTHROPIC_TOKEN", "sk-ant-oat01-static-token")

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")
      File.rm_rf!(tmp_dir)
    end)

    settings =
      settings(%{
        "anthropic" => %{
          auth_source: "oauth"
        }
      })

    session = start_session(self(), settings, mock_model(:anthropic))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "sk-ant-oat01-refreshable-token"}, 1_000
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

  test "resolves provider-specific oauth secrets for stream api keys" do
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

  test "google gemini cli oauth secret resolves to json token+projectId" do
    oauth_secret =
      Jason.encode!(%{
        "type" => "google_gemini_cli_oauth",
        "refresh_token" => "gemini-refresh-token",
        "access_token" => "gemini-access-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "managed_project_id" => "managed-proj-123",
        "project_id" => "managed-proj-123",
        "projectId" => "managed-proj-123",
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, _} = Secrets.set("llm_google_gemini_cli_api_key", oauth_secret)

    settings =
      settings(%{
        "google_gemini_cli" => %{api_key_secret: "llm_google_gemini_cli_api_key"}
      })

    session = start_session(self(), settings, mock_model(:google_gemini_cli))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, resolved_key}, 1_000
    assert_receive {:stream_project, nil}, 1_000
    assert {:ok, decoded} = Jason.decode(resolved_key)
    assert decoded["token"] == "gemini-access-token"
    assert decoded["projectId"] == "managed-proj-123"

    GenServer.stop(session)
  end

  test "google gemini cli resolves runtime project override from env" do
    oauth_secret =
      Jason.encode!(%{
        "type" => "google_gemini_cli_oauth",
        "refresh_token" => "gemini-refresh-token",
        "access_token" => "gemini-access-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "managed_project_id" => "managed-proj-123",
        "project_id" => "managed-proj-123",
        "projectId" => "managed-proj-123",
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, _} = Secrets.set("llm_google_gemini_cli_api_key", oauth_secret)
    System.put_env("LEMON_GEMINI_PROJECT_ID", "env-proj-456")

    settings =
      settings(%{
        "google_gemini_cli" => %{api_key_secret: "llm_google_gemini_cli_api_key"}
      })

    session = start_session(self(), settings, mock_model(:google_gemini_cli))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, resolved_key}, 1_000
    assert_receive {:stream_project, "env-proj-456"}, 1_000
    assert {:ok, decoded} = Jason.decode(resolved_key)
    assert decoded["projectId"] == "managed-proj-123"

    GenServer.stop(session)
  end

  test "google gemini cli resolves runtime project override from provider config" do
    oauth_secret =
      Jason.encode!(%{
        "type" => "google_gemini_cli_oauth",
        "refresh_token" => "gemini-refresh-token",
        "access_token" => "gemini-access-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "managed_project_id" => "managed-proj-123",
        "project_id" => "managed-proj-123",
        "projectId" => "managed-proj-123",
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, _} = Secrets.set("llm_google_gemini_cli_api_key", oauth_secret)

    settings =
      settings(%{
        "google_gemini_cli" => %{
          api_key_secret: "llm_google_gemini_cli_api_key",
          project_id: "config-proj-789"
        }
      })

    session = start_session(self(), settings, mock_model(:google_gemini_cli))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, resolved_key}, 1_000
    assert_receive {:stream_project, "config-proj-789"}, 1_000
    assert {:ok, decoded} = Jason.decode(resolved_key)
    assert decoded["projectId"] == "managed-proj-123"

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

  test "openai codex oauth secret resolves when provider config uses underscored alias" do
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
        "openai_codex" => %{auth_source: "oauth", api_key_secret: "llm_openai_codex_api_key"}
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

  test "openai codex api_key auth resolves when provider config uses underscored alias" do
    System.put_env("OPENAI_CODEX_API_KEY", "codex-from-env")

    settings =
      settings(%{
        "openai_codex" => %{auth_source: "api_key"}
      })

    session = start_session(self(), settings, mock_model(:"openai-codex"))
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "codex-from-env"}, 1_000
    GenServer.stop(session)
  end

  # Public Session wire: no stream_fn, so ProviderFallback drives the real
  # OpenAICodexResponses backend against a loopback listener. Without an
  # auth_source, Credentials refuses the provider; the backend's own ambient
  # fallback (OPENAI_CODEX_API_KEY, then CHATGPT_TOKEN) must not replace that
  # refusal. Every planted value is a well-formed ChatGPT JWT, so a leak would
  # reach the listener instead of failing token parsing first.
  test "openai-codex requires auth_source on the public session wire" do
    base_url = wire_endpoint(:"openai-codex")
    plain_key = codex_jwt("acct-configured-plain-key", "codex-from-plain")
    env_trap = codex_jwt("acct-ambient-codex-env-trap", "codex-env-trap-signature")
    chatgpt_trap = codex_jwt("acct-ambient-chatgpt-trap", "chatgpt-token-trap-signature")

    System.put_env("OPENAI_CODEX_API_KEY", env_trap)
    System.put_env("CHATGPT_TOKEN", chatgpt_trap)

    settings =
      wire_settings(%{
        "openai-codex" => %{api_key: plain_key, base_url: base_url}
      })

    session =
      start_wire_session(settings, wire_model(:"openai-codex", :openai_codex_responses, base_url))

    assert :ok = Session.prompt(session, "hello")
    assert_receive {:session_event, _, {:error, reason, _partial}}, 1_000

    assert_refused_before_wire(session, reason, [
      plain_key,
      "codex-from-plain",
      "acct-configured-plain-key",
      env_trap,
      "codex-env-trap-signature",
      "acct-ambient-codex-env-trap",
      chatgpt_trap,
      "chatgpt-token-trap-signature",
      "acct-ambient-chatgpt-trap"
    ])
  end

  # Public Session wire through the real Anthropic backend. An OAuth payload
  # stored under api_key_secret (no auth_source) is not a raw API key, and only
  # an explicit auth_source = "oauth" may use ambient Claude credentials
  # (CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_TOKEN, ~/.claude/.credentials.json).
  # ANTHROPIC_API_KEY stays unset: in this mode it is the legitimate env-first
  # credential, not a trap.
  test "anthropic oauth payload secret is rejected for provider api-key resolution on the public session wire" do
    base_url = wire_endpoint(:anthropic)
    now = System.system_time(:millisecond)
    access_token = "sk-ant-oat01-configured-payload-access-token"
    refresh_token = "sk-ant-ort01-configured-payload-refresh-token"

    oauth_secret =
      Jason.encode!(%{
        "type" => "anthropic_oauth",
        "refresh_token" => refresh_token,
        "access_token" => access_token,
        "expires_at_ms" => now + 3_600_000,
        "created_at_ms" => now,
        "updated_at_ms" => now
      })

    assert {:ok, _} = Secrets.set("llm_anthropic_api_key", oauth_secret)

    System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-ambient-claude-code-env-trap")
    System.put_env("ANTHROPIC_TOKEN", "sk-ant-oat01-ambient-anthropic-token-trap")

    credentials_path = Path.join([System.get_env("HOME"), ".claude", ".credentials.json"])
    File.mkdir_p!(Path.dirname(credentials_path))

    File.write!(
      credentials_path,
      Jason.encode!(%{
        "claudeAiOauth" => %{
          "accessToken" => "sk-ant-oat01-ambient-credentials-file-trap",
          "refreshToken" => "ambient-credentials-file-refresh-trap",
          "expiresAt" => now + 3_600_000
        }
      })
    )

    settings =
      wire_settings(%{
        "anthropic" => %{api_key_secret: "llm_anthropic_api_key", base_url: base_url}
      })

    session = start_wire_session(settings, wire_model(:anthropic, :anthropic_messages, base_url))

    assert :ok = Session.prompt(session, "hello")
    assert_receive {:session_event, _, {:error, reason, _partial}}, 1_000

    assert_refused_before_wire(session, reason, [
      oauth_secret,
      access_token,
      refresh_token,
      "sk-ant-oat01-ambient-claude-code-env-trap",
      "sk-ant-oat01-ambient-anthropic-token-trap",
      "sk-ant-oat01-ambient-credentials-file-trap",
      "ambient-credentials-file-refresh-trap"
    ])
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
        cwd: Process.get(:session_cwd),
        model: model,
        settings_manager: settings_manager,
        stream_fn: stream_fn(test_pid)
      )

    session
  end

  defp wire_settings(providers) do
    %{settings(providers) | compaction_enabled: false, retry_enabled: false}
  end

  defp start_wire_session(settings_manager, model) do
    session =
      start_supervised!(
        {Session,
         cwd: Process.get(:session_cwd),
         model: model,
         settings_manager: settings_manager,
         tools: [],
         system_prompt: "Reply briefly."}
      )

    Session.subscribe(session)
    session
  end

  defp wire_model(provider, api, base_url) do
    %{mock_model(provider) | api: api, base_url: base_url}
  end

  # Real HTTP to a loopback listener. Shared breaker and credential-health state
  # is reset so an earlier failure cannot refuse the request this test observes.
  defp wire_endpoint(provider) do
    saved_req = Req.default_options()
    Req.default_options(Keyword.drop(saved_req, [:plug, :adapter, :base_url]))
    LemonAi.CircuitBreaker.reset(provider)
    CredentialHealth.reset()

    on_exit(fn ->
      Req.default_options(saved_req)
      LemonAi.CircuitBreaker.reset(provider)
      CredentialHealth.reset()
    end)

    server =
      start_supervised!(
        {Bandit,
         plug: {WireEndpoint, test_pid: self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  defp codex_jwt(account_id, signature) do
    encode = &Base.url_encode64(Jason.encode!(&1), padding: false)
    claims = %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}}
    Enum.join([encode.(%{"alg" => "none", "typ" => "JWT"}), encode.(claims), signature], ".")
  end

  # Called after the session's terminal error: a request the backend sent was
  # recorded by the listener before its response produced that terminal.
  defp assert_refused_before_wire(session, reason, secrets) do
    requests = received_wire_requests([])

    observed =
      inspect({reason, requests, Session.get_messages(session)},
        limit: :infinity,
        printable_limit: :infinity
      )

    assert Enum.filter(secrets, &String.contains?(observed, &1)) == []
    assert requests == []
  end

  defp received_wire_requests(acc) do
    receive do
      {:wire, _method, _path, _headers, _body} = request ->
        received_wire_requests([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp stream_fn(test_pid) do
    fn _model, _context, options ->
      send(test_pid, {:stream_api_key, options.api_key})
      send(test_pid, {:stream_project, options.project})
      {:ok, response_stream()}
    end
  end

  defp response_stream do
    response = assistant_message("ok")
    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, response})
      LemonAi.EventStream.push(stream, {:done, response.stop_reason, response})
      LemonAi.EventStream.complete(stream, response)
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
