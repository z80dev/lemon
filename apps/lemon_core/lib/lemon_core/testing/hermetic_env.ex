defmodule LemonCore.Testing.HermeticEnv do
  @moduledoc """
  Shared helpers for keeping non-integration tests isolated from ambient machine state.

  The default unit-test lane should not accidentally inherit a developer's real
  provider or platform credentials. Tests that intentionally exercise live
  integrations must opt in explicitly with `LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1`
  or by passing `allow_live?: true`.
  """

  @credential_env_vars ~w(
    AI21_API_KEY
    ANTHROPIC_API_KEY
    ANTHROPIC_TOKEN
    AWS_ACCESS_KEY_ID
    AWS_PROFILE
    AWS_SECRET_ACCESS_KEY
    AWS_SESSION_TOKEN
    AZURE_OPENAI_API_KEY
    BRAVE_API_KEY
    CHATGPT_TOKEN
    CLAUDE_CODE_OAUTH_TOKEN
    DEEPGRAM_API_KEY
    DINGTALK_BOT_TOKEN
    DISCORD_BOT_TOKEN
    ELEVENLABS_API_KEY
    FEISHU_APP_SECRET
    FEISHU_BOT_TOKEN
    FIREWORKS_API_KEY
    GEMINI_API_KEY
    GH_TOKEN
    GITHUB_COPILOT_API_KEY
    GITHUB_TOKEN
    GOOGLE_API_KEY
    GOOGLE_APPLICATION_CREDENTIALS
    GOOGLE_APPLICATION_CREDENTIALS_JSON
    GOOGLE_CLOUD_PROJECT
    GOOGLE_CLOUD_PROJECT_ID
    GOOGLE_GENERATIVE_AI_API_KEY
    GOOGLE_GEMINI_CLI_API_KEY
    GROQ_API_KEY
    KIMI_API_KEY
    LEMON_EVAL_API_KEY
    LEMON_SECRETS_MASTER_KEY
    MINIMAX_API_KEY
    MISTRAL_API_KEY
    MOONSHOT_API_KEY
    NOUS_API_KEY
    OPENAI_API_KEY
    OPENAI_CODEX_API_KEY
    OPENCODE_API_KEY
    OPENROUTER_API_KEY
    INTEGRATION_API_KEY
    SLACK_APP_TOKEN
    SLACK_BOT_TOKEN
    TELEGRAM_BOT_TOKEN
    TWILIO_AUTH_TOKEN
    XAI_API_KEY
    X_API_ACCESS_TOKEN
    X_API_ACCESS_TOKEN_SECRET
    X_API_BEARER_TOKEN
    X_API_CLIENT_ID
    X_API_CLIENT_SECRET
    X_API_CONSUMER_KEY
    X_API_CONSUMER_SECRET
    X_API_REFRESH_TOKEN
    X_BEARER_TOKEN
    XMTP_WALLET_KEY
    ZAI_API_KEY
  )

  @live_opt_in_env "LEMON_TEST_ALLOW_LIVE_CREDENTIALS"

  @doc """
  Returns env vars considered live provider/platform credentials in unit tests.
  """
  @spec credential_env_vars() :: [String.t()]
  def credential_env_vars, do: @credential_env_vars

  @doc """
  Scrubs live provider/platform credentials for normal unit-test lanes.

  Set `LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1` or pass `allow_live?: true` for an
  explicit live/integration run that should inherit credentials.

  Returns `:ok` when credentials are scrubbed, or
  `{:skipped, :live_credentials_allowed}` when live credentials are explicitly
  allowed.
  """
  @spec scrub_unit_credentials!(keyword()) :: :ok | {:skipped, :live_credentials_allowed}
  def scrub_unit_credentials!(opts \\ []) do
    if Keyword.get(opts, :allow_live?, false) or live_credentials_allowed?() do
      {:skipped, :live_credentials_allowed}
    else
      Enum.each(@credential_env_vars, &System.delete_env/1)
      :ok
    end
  end

  @doc """
  Runs `fun` and restores the provided env vars afterward.

  This helper is intentionally small and synchronous. Use it from `async: false`
  tests when mutating process-wide environment variables.
  """
  @spec with_restored_env([String.t()], (-> result)) :: result when result: term()
  def with_restored_env(keys, fun) when is_list(keys) and is_function(fun, 0) do
    snapshot = snapshot_env(keys)

    try do
      fun.()
    after
      restore_env(snapshot)
    end
  end

  @doc """
  Captures current values for env vars.
  """
  @spec snapshot_env([String.t()]) :: %{String.t() => String.t() | nil}
  def snapshot_env(keys) when is_list(keys) do
    Map.new(keys, fn key -> {key, System.get_env(key)} end)
  end

  @doc """
  Restores env vars captured with `snapshot_env/1`.
  """
  @spec restore_env(%{String.t() => String.t() | nil}) :: :ok
  def restore_env(snapshot) when is_map(snapshot) do
    Enum.each(snapshot, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    :ok
  end

  defp live_credentials_allowed? do
    System.get_env(@live_opt_in_env) in ["1", "true", "TRUE", "yes", "YES"]
  end
end
