defmodule LemonCore.Config.Providers do
  @moduledoc """
  LLM provider configuration for API keys and base URLs.

  Inspired by Ironclaw's modular config pattern, this module handles
  provider-specific configuration including API keys, base URLs, and
  secret references for LLM providers like Anthropic, OpenAI, etc.

  ## Configuration

  Configuration is loaded from the TOML config file under `[providers]`:

      [providers.anthropic]
      api_key_secret = "llm_anthropic_api_key_raw"
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
  - `OPENCODE_API_KEY`, `OPENCODE_BASE_URL` (OpenCode and OpenCode Go)
  - `GITHUB_COPILOT_API_KEY`

  Local OpenAI-compatible servers take a default `base_url` from
  `OLLAMA_BASE_URL`/`OLLAMA_HOST`, `LM_STUDIO_BASE_URL`, `LLAMA_CPP_BASE_URL`
  and `LITELLM_BASE_URL` (normalized to a `/v1` root); a `base_url` set in the
  file takes precedence over these.

  The `api_key_secret` field allows referencing secrets from the secret store
  instead of hardcoding API keys in config files.

  For providers that support OAuth payloads (`anthropic`, `openai-codex`,
  `google_gemini_cli`), set `auth_source = "oauth"` to resolve credential
  payloads from encrypted secrets. Anthropic keeps raw API keys in
  `llm_anthropic_api_key_raw` and Claude Code OAuth payloads in
  `llm_anthropic_api_key` to avoid mixing header modes. `google_gemini_cli`
  stores its OAuth payload in `api_key_secret` because the runtime provider
  expects a JSON `{"token","projectId"}` value.
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
          oauth_secret: String.t() | nil,
          project: String.t() | nil,
          project_id: String.t() | nil,
          project_secret: String.t() | nil,
          location: String.t() | nil,
          location_secret: String.t() | nil,
          service_account_json: String.t() | nil,
          service_account_json_secret: String.t() | nil
        }

  @type t :: %__MODULE__{
          providers: %{optional(String.t()) => provider_config()}
        }

  # Environment variable mappings for known providers
  @provider_env_mappings %{
    "anthropic" => %{api_key: "ANTHROPIC_API_KEY", base_url: "ANTHROPIC_BASE_URL"},
    "openai" => %{api_key: "OPENAI_API_KEY", base_url: "OPENAI_BASE_URL"},
    "openai-codex" => %{api_key: "OPENAI_CODEX_API_KEY", base_url: "OPENAI_BASE_URL"},
    "google_gemini_cli" => %{api_key: "GOOGLE_GEMINI_CLI_API_KEY"},
    "opencode" => %{api_key: "OPENCODE_API_KEY", base_url: "OPENCODE_BASE_URL"},
    "opencode_go" => %{api_key: "OPENCODE_API_KEY"},
    "github_copilot" => %{api_key: "GITHUB_COPILOT_API_KEY"},
    "zai" => %{api_key: "ZAI_API_KEY", base_url: "ZAI_BASE_URL"},
    "minimax" => %{api_key: "MINIMAX_API_KEY", base_url: "MINIMAX_BASE_URL"}
  }

  # Base-URL environment variables for local OpenAI-compatible servers (omp
  # names). Unlike the mappings above, an explicit `[providers.<id>].base_url`
  # wins (under any alias spelling such as `lm-studio` or `llama.cpp`); values
  # are normalized to the OpenAI-compatible `/v1` root. First set variable wins.
  @local_base_url_env [
    {"ollama", ["OLLAMA_BASE_URL", "OLLAMA_HOST"]},
    {"lm_studio", ["LM_STUDIO_BASE_URL"]},
    {"llama_cpp", ["LLAMA_CPP_BASE_URL"]},
    {"litellm", ["LITELLM_BASE_URL"]}
  ]

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
      |> apply_local_base_url_env()

    %__MODULE__{
      providers: resolved_providers
    }
  end

  # Private functions for resolving each provider config

  defp resolve_provider(config) when is_map(config) do
    base = %{
      api_key: config["api_key"],
      base_url: config["base_url"],
      api_key_secret: normalize_optional_string(config["api_key_secret"]),
      auth_source: normalize_optional_string(config["auth_source"]),
      oauth_secret: normalize_optional_string(config["oauth_secret"]),
      project: normalize_optional_string(config["project"]),
      project_id: normalize_optional_string(config["project_id"] || config["projectId"]),
      # Google Vertex fields
      location: normalize_optional_string(config["location"]),
      service_account_json: normalize_optional_string(config["service_account_json"]),
      project_secret: normalize_optional_string(config["project_secret"]),
      location_secret: normalize_optional_string(config["location_secret"]),
      service_account_json_secret:
        normalize_optional_string(config["service_account_json_secret"]),
      # Azure OpenAI Responses fields
      resource_name: normalize_optional_string(config["resource_name"]),
      api_version: normalize_optional_string(config["api_version"]),
      deployment_name_map: config["deployment_name_map"],
      # Amazon Bedrock fields
      region: normalize_optional_string(config["region"]),
      access_key_id_secret: normalize_optional_string(config["access_key_id_secret"]),
      secret_access_key_secret: normalize_optional_string(config["secret_access_key_secret"]),
      session_token_secret: normalize_optional_string(config["session_token_secret"])
    }

    reject_nil_values(base)
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

    api_key = env_var_value(env_vars[:api_key])
    base_url = env_var_value(env_vars[:base_url])

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

  defp env_var_value(name) when is_binary(name), do: Helpers.get_env(name)
  defp env_var_value(_), do: nil

  defp apply_local_base_url_env(providers) do
    Enum.reduce(@local_base_url_env, providers, fn {canonical, vars}, acc ->
      key = Enum.find(Map.keys(acc), canonical, &(provider_key(&1) == canonical))
      existing = Map.get(acc, key, %{})

      with nil <- existing[:base_url],
           url when is_binary(url) <- Enum.find_value(vars, &local_base_url(&1)) do
        Map.put(acc, key, Map.put(existing, :base_url, url))
      else
        _ -> acc
      end
    end)
  end

  defp provider_key(name) when is_binary(name),
    do: name |> String.trim() |> String.downcase() |> String.replace(["-", "."], "_")

  defp provider_key(_), do: nil

  defp local_base_url("OLLAMA_HOST" = var) do
    case env_var_value(var) do
      value when is_binary(value) -> value |> ollama_host_url() |> ensure_v1()
      _ -> nil
    end
  end

  defp local_base_url(var), do: var |> env_var_value() |> ensure_v1()

  # OLLAMA_HOST is a bind address ("0.0.0.0", ":11434", "host:port"); omp turns
  # it into a client URL, defaulting the scheme to http and the port to 11434.
  defp ollama_host_url(value) do
    trimmed = String.trim(value)

    candidate =
      cond do
        trimmed == "" -> nil
        String.contains?(trimmed, "://") -> trimmed
        String.starts_with?(trimmed, "//") -> "http:" <> trimmed
        String.starts_with?(trimmed, ":") -> "http://127.0.0.1" <> trimmed
        true -> "http://" <> trimmed
      end

    with candidate when is_binary(candidate) <- candidate,
         %URI{scheme: scheme, host: host} = uri when scheme in ["http", "https"] and host != "" <-
           URI.parse(candidate) do
      port_suffix =
        cond do
          String.match?(candidate, ~r{^[a-z]+://(\[[^\]]*\]|[^/:\[]*):\d+}i) -> ":#{uri.port}"
          scheme == "http" -> ":11434"
          true -> ""
        end

      host = if String.contains?(host, ":"), do: "[#{host}]", else: host
      "#{scheme}://#{host}#{port_suffix}"
    else
      _ -> nil
    end
  end

  defp ensure_v1(value) when is_binary(value) do
    trimmed = value |> String.trim() |> String.trim_trailing("/")

    cond do
      trimmed == "" -> nil
      String.ends_with?(trimmed, "/v1") -> trimmed
      true -> trimmed <> "/v1"
    end
  end

  defp ensure_v1(_), do: nil

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
          resolve_api_key_secret(provider[:api_key_secret])
        end
    end
  end

  # Resolves api_key_secret reference using LemonCore.Secrets if available
  defp resolve_api_key_secret(nil), do: nil

  defp resolve_api_key_secret(secret_name) when is_binary(secret_name) do
    # Check if Secrets module is available and configured
    if secrets_available?() do
      try do
        case LemonCore.Secrets.resolve(secret_name, env_fallback: true) do
          {:ok, value, _source} -> value
          {:error, _reason} -> nil
        end
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end
    else
      # Fallback to direct environment variable lookup
      System.get_env(secret_name)
    end
  end

  defp secrets_available? do
    Code.ensure_loaded?(LemonCore.Secrets) and
      function_exported?(LemonCore.Secrets, :resolve, 2)
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
