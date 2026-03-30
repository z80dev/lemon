defmodule LemonCore.Onboarding.Providers do
  @moduledoc false

  alias LemonCore.Onboarding.Provider

  @providers [
    %Provider{
      id: "anthropic",
      display_name: "Anthropic",
      description: "Claude Code OAuth or API key",
      provider_table: "providers.anthropic",
      default_secret_name: "llm_anthropic_api_key",
      default_secret_name_by_mode: %{
        api_key: "llm_anthropic_api_key_raw",
        oauth: "llm_anthropic_api_key"
      },
      api_key_secret_provider: "onboarding_anthropic",
      oauth_secret_provider: "onboarding_anthropic_oauth",
      oauth_module: Module.concat([:"Elixir.Ai", :Auth, :AnthropicOAuth]),
      auth_modes: [:oauth, :api_key],
      default_auth_mode: :oauth,
      preferred_models: [
        "claude-sonnet-4-20250514",
        "claude-sonnet-4-5-20250929",
        "claude-opus-4-6"
      ],
      aliases: ["claude"],
      api_key_prompt: "Enter your Anthropic API key: ",
      api_key_choice_label: "Paste API key",
      oauth_choice_label: "Claude Code login (OAuth)",
      oauth_failure_label: "Anthropic Claude OAuth login failed",
      token_resolution_hint:
        "Anthropic OAuth flow did not return credentials. Retry and complete `claude setup-token`, or pass --token for API-key mode.",
      auth_source_by_mode: %{api_key: "api_key", oauth: "oauth"},
      secret_config_key_by_mode: %{api_key: "api_key_secret", oauth: "oauth_secret"}
    },
    %Provider{
      id: "openai",
      display_name: "OpenAI",
      description: "OpenAI API key",
      provider_table: "providers.openai",
      default_secret_name: "llm_openai_api_key",
      api_key_secret_provider: "onboarding_openai",
      auth_modes: [:api_key],
      default_auth_mode: :api_key,
      preferred_models: ["gpt-5", "gpt-5-mini", "gpt-4.1"],
      api_key_prompt: "Enter your OpenAI API key: ",
      api_key_choice_label: "Paste API key"
    },
    %Provider{
      id: "openai-codex",
      display_name: "OpenAI Codex",
      description: "ChatGPT Codex OAuth or token",
      provider_table: "providers.openai-codex",
      default_secret_name: "llm_openai_codex_api_key",
      api_key_secret_provider: "onboarding_openai_codex",
      oauth_secret_provider: "onboarding_openai_codex_oauth",
      oauth_module: Module.concat([:"Elixir.Ai", :Auth, :OpenAICodexOAuth]),
      auth_modes: [:oauth, :api_key],
      default_auth_mode: :oauth,
      preferred_models: ["gpt-5.2", "gpt-5", "gpt-5-mini"],
      aliases: ["codex", "openai_codex"],
      api_key_prompt: "Enter your OpenAI Codex token: ",
      api_key_choice_label: "Paste existing token",
      oauth_choice_label: "Browser sign-in (OAuth)",
      oauth_failure_label: "OpenAI Codex OAuth login failed",
      token_resolution_hint:
        "OpenAI Codex OAuth flow did not return credentials. Retry and paste the callback URL/code, or pass --token.",
      auth_source_by_mode: %{api_key: "api_key", oauth: "oauth"},
      secret_config_key_by_mode: %{api_key: "api_key_secret", oauth: "oauth_secret"}
    },
    %Provider{
      id: "github_copilot",
      display_name: "GitHub Copilot",
      description: "GitHub device login or token",
      provider_table: "providers.github_copilot",
      default_secret_name: "llm_github_copilot_api_key",
      api_key_secret_provider: "onboarding_copilot",
      oauth_secret_provider: "onboarding_copilot_oauth",
      oauth_module: Module.concat([:"Elixir.Ai", :Auth, :GitHubCopilotOAuth]),
      auth_modes: [:oauth, :api_key],
      default_auth_mode: :oauth,
      preferred_models: ["gpt-5", "claude-sonnet-4-20250514", "gemini-2.5-pro"],
      aliases: ["copilot", "github-copilot"],
      switches: [enterprise_domain: :string, skip_enable_models: :boolean],
      oauth_opts_builder: &__MODULE__.copilot_oauth_opts/1,
      api_key_prompt: "Enter your GitHub Copilot token: ",
      api_key_choice_label: "Paste existing token",
      oauth_choice_label: "Browser sign-in (device flow)",
      oauth_failure_label: "GitHub Copilot OAuth login failed"
    },
    %Provider{
      id: "google_antigravity",
      display_name: "Google Antigravity",
      description: "Google OAuth or credential payload",
      provider_table: "providers.google_antigravity",
      default_secret_name: "llm_google_antigravity_api_key",
      api_key_secret_provider: "onboarding_google_antigravity",
      oauth_secret_provider: "onboarding_google_antigravity_oauth",
      oauth_module: Module.concat([:"Elixir.Ai", :Auth, :GoogleAntigravityOAuth]),
      auth_modes: [:oauth, :api_key],
      default_auth_mode: :oauth,
      preferred_models: ["gemini-3-pro-high", "gemini-3-pro-low", "gemini-3-flash"],
      aliases: ["antigravity", "google-antigravity"],
      api_key_prompt:
        "Paste an Antigravity credential payload (for example JSON with token/projectId): ",
      api_key_choice_label: "Paste existing credential",
      oauth_choice_label: "Browser sign-in (OAuth)",
      oauth_failure_label: "Google Antigravity OAuth login failed"
    },
    %Provider{
      id: "zai",
      display_name: "Z.AI (GLM)",
      description: "Z.AI API key for GLM models",
      provider_table: "providers.zai",
      default_secret_name: "llm_zai_api_key",
      api_key_secret_provider: "onboarding_zai",
      auth_modes: [:api_key],
      default_auth_mode: :api_key,
      preferred_models: ["glm-5", "glm-5-turbo", "glm-4.7"],
      aliases: ["glm", "zhipu", "z-ai", "z.ai"],
      api_key_prompt: "Enter your Z.AI API key: ",
      api_key_choice_label: "Paste API key",
      auth_source_by_mode: %{api_key: "api_key"}
    },
    %Provider{
      id: "kimi",
      display_name: "Kimi",
      description: "Kimi API key for K2 models",
      provider_table: "providers.kimi",
      default_secret_name: "llm_kimi_api_key",
      api_key_secret_provider: "onboarding_kimi",
      auth_modes: [:api_key],
      default_auth_mode: :api_key,
      preferred_models: ["k2p5", "kimi-k2-thinking", "kimi-for-coding"],
      aliases: ["kimi-k2", "moonshot"],
      api_key_prompt: "Enter your Kimi API key: ",
      api_key_choice_label: "Paste API key",
      auth_source_by_mode: %{api_key: "api_key"}
    },
    %Provider{
      id: "minimax",
      display_name: "MiniMax",
      description: "MiniMax API key for M2 models",
      provider_table: "providers.minimax",
      default_secret_name: "llm_minimax_api_key",
      api_key_secret_provider: "onboarding_minimax",
      auth_modes: [:api_key],
      default_auth_mode: :api_key,
      preferred_models: ["MiniMax-M2.7", "MiniMax-M2.7-highspeed", "MiniMax-M2.5"],
      aliases: ["mini-max", "minimax-m2"],
      api_key_prompt: "Enter your MiniMax API key: ",
      api_key_choice_label: "Paste API key",
      auth_source_by_mode: %{api_key: "api_key"}
    },
    %Provider{
      id: "fireworks",
      display_name: "Fireworks AI",
      description: "Fireworks API key for open-weight models",
      provider_table: "providers.fireworks",
      default_secret_name: "llm_fireworks_api_key",
      api_key_secret_provider: "onboarding_fireworks",
      auth_modes: [:api_key],
      default_auth_mode: :api_key,
      preferred_models: [
        "accounts/fireworks/routers/kimi-k2p5-turbo",
        "accounts/fireworks/models/deepseek-v3p2",
        "accounts/fireworks/models/glm-4p7"
      ],
      aliases: ["fireworks-ai", "fireworks_ai"],
      api_key_prompt: "Enter your Fireworks API key: ",
      api_key_choice_label: "Paste API key",
      auth_source_by_mode: %{api_key: "api_key"}
    },
    %Provider{
      id: "google_gemini_cli",
      display_name: "Google Gemini CLI",
      description: "Google OAuth for Gemini CLI / Code Assist",
      provider_table: "providers.google_gemini_cli",
      default_secret_name: "llm_google_gemini_cli_api_key",
      api_key_secret_provider: "onboarding_google_gemini_cli",
      oauth_secret_provider: "onboarding_google_gemini_cli_oauth",
      oauth_module: Module.concat([:"Elixir.Ai", :Auth, :GoogleGeminiCliOAuth]),
      auth_modes: [:oauth, :api_key],
      default_auth_mode: :oauth,
      preferred_models: [
        "gemini-2.5-pro",
        "gemini-2.5-flash",
        "gemini-3-pro-preview",
        "gemini-3-flash-preview"
      ],
      aliases: ["gemini", "gemini-cli", "google-gemini-cli"],
      switches: [project_id: :string],
      oauth_opts_builder: &__MODULE__.gemini_cli_oauth_opts/1,
      api_key_prompt:
        "Paste a Gemini CLI credential payload (for example JSON with token/projectId): ",
      api_key_choice_label: "Paste existing credential",
      oauth_choice_label: "Browser sign-in (Gemini OAuth)",
      oauth_failure_label: "Google Gemini CLI OAuth login failed",
      auth_source_by_mode: %{api_key: "api_key", oauth: "oauth"},
      secret_config_key_by_mode: %{api_key: "api_key_secret", oauth: "api_key_secret"}
    }
  ]

  @spec list() :: [Provider.t()]
  def list, do: @providers

  @spec find(String.t() | atom()) :: Provider.t() | nil
  def find(value) when is_atom(value), do: value |> Atom.to_string() |> find()

  def find(value) when is_binary(value) do
    normalized = normalize_name(value)

    Enum.find(@providers, fn %Provider{id: id, aliases: aliases} ->
      normalize_name(id) == normalized or Enum.any?(aliases, &(normalize_name(&1) == normalized))
    end)
  end

  def find(_), do: nil

  @spec fetch!(String.t() | atom()) :: Provider.t()
  def fetch!(value) do
    case find(value) do
      %Provider{} = provider ->
        provider

      nil ->
        names =
          @providers
          |> Enum.map(& &1.id)
          |> Enum.join(", ")

        Mix.raise("Unknown provider #{inspect(value)}. Available providers: #{names}")
    end
  end

  @spec auth_summary(Provider.t()) :: String.t()
  def auth_summary(%Provider{auth_modes: modes}) do
    modes
    |> Enum.map(&auth_mode_label/1)
    |> Enum.join(" / ")
  end

  @spec menu_status(Provider.t(), String.t()) :: String.t()
  def menu_status(%Provider{} = provider, config_path) when is_binary(config_path) do
    config =
      config_path
      |> Path.expand()
      |> read_config()

    provider_cfg = provider_config(config, provider.id)
    default_provider = get_in(config, ["defaults", "provider"])

    cond do
      default_provider == provider.id and provider_cfg == %{} ->
        "default"

      provider_cfg == %{} ->
        "not configured"

      default_provider == provider.id ->
        "configured, default"

      true ->
        config_status(provider_cfg)
    end
  end

  defp config_status(provider_cfg) when is_map(provider_cfg) do
    auth_source =
      provider_cfg
      |> Map.get("auth_source")
      |> normalize_optional_string()

    cond do
      auth_source == "oauth" -> "oauth configured"
      auth_source == "api_key" -> "api key configured"
      is_binary(Map.get(provider_cfg, "oauth_secret")) -> "oauth configured"
      is_binary(Map.get(provider_cfg, "api_key_secret")) -> "configured"
      true -> "configured"
    end
  end

  defp provider_config(config, provider_id) do
    get_in(config, ["providers", provider_id]) || %{}
  end

  defp read_config(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Toml.decode(content) do
      decoded
    else
      _ -> %{}
    end
  end

  defp normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: String.downcase(value)
  end

  defp normalize_optional_string(_), do: nil

  defp normalize_name(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("_", "-")
  end

  @doc false
  def copilot_oauth_opts(opts) do
    Keyword.merge(opts,
      enterprise_domain: Keyword.get(opts, :enterprise_domain),
      enable_models: !Keyword.get(opts, :skip_enable_models, false)
    )
  end

  @doc false
  def gemini_cli_oauth_opts(opts) do
    Keyword.merge(opts,
      project_id:
        Keyword.get(opts, :project_id) ||
          System.get_env("LEMON_GEMINI_PROJECT_ID") ||
          System.get_env("GOOGLE_CLOUD_PROJECT") ||
          System.get_env("GOOGLE_CLOUD_PROJECT_ID") ||
          System.get_env("GCLOUD_PROJECT")
    )
  end

  defp auth_mode_label(:oauth), do: "OAuth"
  defp auth_mode_label(:api_key), do: "API key"
end
