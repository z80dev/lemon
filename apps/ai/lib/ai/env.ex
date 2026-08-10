defmodule Ai.Env do
  @moduledoc """
  Environment variables read by `ai` — provider credentials, endpoints, and model-client tuning.

  Aggregated by `LemonCore.Env` through the `:env_registries` list; see
  `LemonCore.Env.Registry`.
  """

  @declarations [
    %{
      name: :lemon_ai_debug,
      env_var: "LEMON_AI_DEBUG",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether raw Anthropic SSE traffic is logged to a debug file.",
      secret?: false,
      required?: false,
      area: :ai_diagnostics,
      apps: [:ai]
    },
    %{
      name: :lemon_ai_debug_file,
      env_var: "LEMON_AI_DEBUG_FILE",
      aliases: [],
      type: :string,
      default: "/tmp/lemon_anthropic_sse.log",
      doc: "File path used for Anthropic SSE debug logging.",
      secret?: false,
      required?: false,
      area: :ai_diagnostics,
      apps: [:ai]
    },
    %{
      name: :lemon_ai_http_trace,
      env_var: "LEMON_AI_HTTP_TRACE",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether low-level HTTP request/response tracing is enabled for provider calls.",
      secret?: false,
      required?: false,
      area: :ai_diagnostics,
      apps: [:ai]
    },
    %{
      name: :lemon_ai_prompt_diagnostics,
      env_var: "LEMON_AI_PROMPT_DIAGNOSTICS",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether prompt diagnostics logging is enabled.",
      secret?: false,
      required?: false,
      area: :ai_diagnostics,
      apps: [:ai]
    },
    %{
      name: :lemon_ai_prompt_diagnostics_log_level,
      env_var: "LEMON_AI_PROMPT_DIAGNOSTICS_LOG_LEVEL",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Log level used for prompt diagnostics output.",
      secret?: false,
      required?: false,
      area: :ai_diagnostics,
      apps: [:ai]
    },
    %{
      name: :lemon_ai_prompt_diagnostics_top_n,
      env_var: "LEMON_AI_PROMPT_DIAGNOSTICS_TOP_N",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Number of top prompt-diagnostics entries to report.",
      secret?: false,
      required?: false,
      area: :ai_diagnostics,
      apps: [:ai]
    },
    %{
      name: :lemon_anthropic_claude_path,
      env_var: "LEMON_ANTHROPIC_CLAUDE_PATH",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Override path to the `claude` executable used for Anthropic OAuth.",
      secret?: false,
      required?: false,
      area: :ai_diagnostics,
      apps: [:ai]
    },
    %{
      name: :lemon_kimi_max_request_messages,
      env_var: "LEMON_KIMI_MAX_REQUEST_MESSAGES",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Max message-history length sent per request to Kimi (history-limited provider).",
      secret?: false,
      required?: false,
      area: :ai_diagnostics,
      apps: [:ai]
    },
    %{
      name: :pi_cache_retention,
      env_var: "PI_CACHE_RETENTION",
      aliases: [],
      type: :string,
      default: nil,
      doc:
        "When set to \"long\", requests 24h prompt-cache retention from OpenAI-compatible providers.",
      secret?: false,
      required?: false,
      area: :ai_diagnostics,
      apps: [:ai]
    },
    %{
      name: :openai_base_url,
      env_var: "OPENAI_BASE_URL",
      aliases: [],
      type: :string,
      default: nil,
      doc: "OpenAI API base URL override (ecosystem-standard name).",
      secret?: false,
      required?: false,
      area: :provider,
      apps: [:ai]
    },
    %{
      name: :azure_openai_api_key,
      env_var: "AZURE_OPENAI_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Azure OpenAI API key.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :chatgpt_token,
      env_var: "CHATGPT_TOKEN",
      aliases: [],
      type: :string,
      default: nil,
      doc: "ChatGPT/Codex session token (fallback for OPENAI_CODEX_API_KEY).",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :gcloud_project,
      env_var: "GCLOUD_PROJECT",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Google Cloud project id (gcloud CLI convention name).",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:ai, :lemon_cli, :lemon_core]
    },
    %{
      name: :gemini_api_key,
      env_var: "GEMINI_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Gemini API key (alt name).",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :github_copilot_client_id,
      env_var: "GITHUB_COPILOT_CLIENT_ID",
      aliases: [],
      type: :string,
      default: nil,
      doc: "GitHub Copilot OAuth client id override.",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :google_api_key,
      env_var: "GOOGLE_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Google Generative AI API key (alt name).",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :google_application_credentials,
      env_var: "GOOGLE_APPLICATION_CREDENTIALS",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Path to a Google service-account JSON credentials file (ecosystem-standard name).",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai, :agent_core]
    },
    %{
      name: :google_cloud_project,
      env_var: "GOOGLE_CLOUD_PROJECT",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Google Cloud project id (ecosystem-standard name).",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:ai, :lemon_cli, :lemon_core]
    },
    %{
      name: :google_cloud_project_id,
      env_var: "GOOGLE_CLOUD_PROJECT_ID",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Google Cloud project id (alt ecosystem name).",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:ai, :lemon_cli, :lemon_core]
    },
    %{
      name: :google_gemini_cli_oauth_client_id,
      env_var: "GOOGLE_GEMINI_CLI_OAUTH_CLIENT_ID",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Google Gemini CLI OAuth client id override.",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :google_gemini_cli_oauth_client_secret,
      env_var: "GOOGLE_GEMINI_CLI_OAUTH_CLIENT_SECRET",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Google Gemini CLI OAuth client secret override.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :google_generative_ai_api_key,
      env_var: "GOOGLE_GENERATIVE_AI_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Google Generative AI API key (primary name).",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :lemon_gemini_project_id,
      env_var: "LEMON_GEMINI_PROJECT_ID",
      aliases: [],
      type: :string,
      default: nil,
      doc:
        "Lemon-specific override for the Gemini/Vertex project id, checked before the GOOGLE_CLOUD_* names.",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:ai, :lemon_cli, :lemon_core]
    },
    %{
      name: :mistral_api_key,
      env_var: "MISTRAL_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Mistral API key.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :openai_api_key,
      env_var: "OPENAI_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "OpenAI API key.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :openai_codex_api_key,
      env_var: "OPENAI_CODEX_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "OpenAI Codex API key.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :openai_codex_oauth_client_id,
      env_var: "OPENAI_CODEX_OAUTH_CLIENT_ID",
      aliases: [],
      type: :string,
      default: nil,
      doc: "OpenAI Codex OAuth client id override.",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :opencode_api_key,
      env_var: "OPENCODE_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "OpenCode provider API key.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    }
  ]

  # `ai` deliberately does not depend on lemon_core, so it implements the
  # registry contract structurally instead of using the macro.
  @spec declarations() :: [map()]
  def declarations, do: @declarations
end
