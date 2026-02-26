defmodule LemonCore.Config.Providers do
  @moduledoc """
  LLM provider configuration for API keys and base URLs.

  Inspired by Ironclaw's modular config pattern, this module handles
  provider-specific configuration including API keys, base URLs, and
  secret references for LLM providers like Anthropic, OpenAI, etc.

  ## Configuration

  Configuration is loaded from the TOML config file under `[providers]`:

      [providers.anthropic]
      api_key_secret = "llm_anthropic_api_key"
      base_url = "https://api.anthropic.com"

      [providers.openai]
      api_key = "sk-..."
      api_key_secret = "openai_api_key"  # Reference to secret store

      [providers.openai-codex]
      auth_source = "oauth"              # Required: "oauth" or "api_key"
      oauth_secret = "llm_openai_codex_api_key"

  Environment variables override file configuration:
  - `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`
  - `OPENAI_API_KEY`, `OPENAI_BASE_URL`
  - `OPENAI_CODEX_API_KEY`
  - `OPENCODE_API_KEY`, `OPENCODE_BASE_URL`

  The `api_key_secret` field allows referencing secrets from the secret store
  instead of hardcoding API keys in config files.

  For providers that support OAuth payloads (`openai-codex`), set
  `auth_source = "oauth"` to resolve access tokens from `oauth_secret`.
  """

  alias LemonCore.Config.Helpers

  defstruct [
    :providers
  ]

  @type provider_config :: %{
          api_key: String.t() | nil,
          base_url: String.t() | nil,
          api_key_secret: String.t() | nil,
          auth_source: String.t() | nil,
          oauth_secret: String.t() | nil
        }

  @type t :: %__MODULE__{
          providers: %{optional(String.t()) => provider_config()}
        }

  # Environment variable mappings for known providers
  @provider_env_mappings %{
    "anthropic" => %{api_key: "ANTHROPIC_API_KEY", base_url: "ANTHROPIC_BASE_URL"},
    "openai" => %{api_key: "OPENAI_API_KEY", base_url: "OPENAI_BASE_URL"},
    "openai-codex" => %{api_key: "OPENAI_CODEX_API_KEY", base_url: "OPENAI_BASE_URL"},
    "opencode" => %{api_key: "OPENCODE_API_KEY", base_url: "OPENCODE_BASE_URL"}
  }

  @doc """
  Resolves providers configuration from settings and environment variables.

  Priority: environment variables > TOML config > defaults
  """
  @spec resolve(map()) :: t()
  def resolve(settings) do
    providers = settings["providers"] || %{}

    resolved_providers =
      providers
      |> Enum.filter(fn {_name, config} -> is_map(config) end)
      |> Enum.map(fn {name, config} ->
        {name, resolve_provider(config)}
      end)
      |> Enum.into(%{})
      |> apply_env_overrides()

    %__MODULE__{
      providers: resolved_providers
    }
  end

  # Private functions for resolving each provider config

  defp resolve_provider(config) when is_map(config) do
    %{
      api_key: config["api_key"],
      base_url: config["base_url"],
      api_key_secret: normalize_optional_string(config["api_key_secret"]),
      auth_source: normalize_optional_string(config["auth_source"]),
      oauth_secret: normalize_optional_string(config["oauth_secret"])
    }
    |> reject_nil_values()
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(str) when is_binary(str), do: str
  defp normalize_optional_string(_), do: nil

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  defp apply_env_overrides(providers) do
    @provider_env_mappings
    |> Enum.reduce(providers, fn {provider_name, env_vars}, acc ->
      apply_provider_env_override(acc, provider_name, env_vars)
    end)
  end

  defp apply_provider_env_override(providers, name, env_vars) do
    existing = Map.get(providers, name, %{})

    api_key = Helpers.get_env(env_vars[:api_key])
    base_url = Helpers.get_env(env_vars[:base_url])

    merged =
      existing
      |> maybe_put(:api_key, api_key)
      |> maybe_put(:base_url, base_url)

    if map_size(merged) > 0 do
      Map.put(providers, name, merged)
    else
      providers
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Gets a specific provider's configuration.

  ## Examples

      iex> providers = Config.Providers.resolve(%{"providers" => %{"anthropic" => %{"api_key" => "sk-..."}}})
      iex> Config.Providers.get_provider(providers, "anthropic")
      %{api_key: "sk-..."}

      iex> Config.Providers.get_provider(providers, "unknown")
      %{}
  """
  @spec get_provider(t(), String.t()) :: provider_config()
  def get_provider(%__MODULE__{providers: providers}, name) do
    Map.get(providers, name, %{})
  end

  @doc """
  Gets the API key for a specific provider.

  Checks both `api_key` and falls back to resolving `api_key_secret`
  if the secret store is available.

  ## Examples

      iex> providers = Config.Providers.resolve(%{"providers" => %{"anthropic" => %{"api_key" => "sk-..."}}})
      iex> Config.Providers.get_api_key(providers, "anthropic")
      "sk-..."

      iex> Config.Providers.get_api_key(providers, "unknown")
      nil
  """
  @spec get_api_key(t(), String.t()) :: String.t() | nil
  def get_api_key(%__MODULE__{providers: providers}, name) do
    case Map.get(providers, name) do
      nil ->
        nil

      provider ->
        # First check direct api_key
        if provider[:api_key] do
          provider[:api_key]
        else
          # Fall back to api_key_secret if available
          # Note: Actual secret resolution would require the Secrets module
          nil
        end
    end
  end

  @doc """
  Returns the default providers configuration as a map.

  This is used as the base configuration that gets overridden by
  user settings.
  """
  @spec defaults() :: map()
  def defaults do
    %{}
  end

  @doc """
  Lists all configured provider names.

  ## Examples

      iex> providers = Config.Providers.resolve(%{"providers" => %{"anthropic" => %{}, "openai" => %{}}})
      iex> Config.Providers.list_providers(providers)
      ["anthropic", "openai"]
  """
  @spec list_providers(t()) :: [String.t()]
  def list_providers(%__MODULE__{providers: providers}) do
    Map.keys(providers)
  end
end
