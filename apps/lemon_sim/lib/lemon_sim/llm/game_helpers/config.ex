defmodule LemonSim.LLM.GameHelpers.Config do
  @moduledoc """
  Shared config resolution for LemonSim games.

  Extracts model and API key resolution that was previously duplicated
  across every game module.
  """

  alias LemonCore.Config.Providers

  @provider_aliases %{
    "gemini" => "google_gemini_cli",
    "gemini_cli" => "google_gemini_cli",
    "gemini-cli" => "google_gemini_cli",
    "openai_codex" => "openai-codex"
  }

  @doc """
  Resolves the configured default model from Lemon config.

  Pass `:error_label` to retain a scenario's user-facing setup error label.
  """
  @spec resolve_configured_model!(map(), String.t(), keyword()) :: LemonAi.Types.Model.t()
  def resolve_configured_model!(config, game_name \\ "game", opts \\ []) do
    provider = config.agent.default_provider
    model_spec = config.agent.default_model
    error_label = Keyword.get(opts, :error_label, "#{game_name} sim")

    case resolve_model_spec(provider, model_spec) do
      %LemonAi.Types.Model{} = model ->
        apply_provider_base_url(model, config)

      nil ->
        raise """
        #{error_label} requires a valid default model.
        Configure [defaults].provider + [defaults].model (or [agent].default_*) in Lemon config,
        or pass an explicit model via the mix task.
        """
    end
  end

  @doc """
  Resolves the API key for a given provider from Lemon config.
  """
  def resolve_provider_api_key!(provider, config, game_name \\ "game") do
    provider_name = provider_name(provider)
    provider_cfg = Providers.get_provider(config.providers, provider_name)

    cond do
      provider_name == "openai-codex" ->
        case resolve_openai_codex_api_key(provider_cfg) do
          token when is_binary(token) and token != "" ->
            token

          _ ->
            raise "#{game_name} sim requires an OpenAI Codex access token"
        end

      is_binary(provider_cfg[:api_key]) and provider_cfg[:api_key] != "" ->
        provider_cfg[:api_key]

      is_binary(provider_cfg[:api_key_secret]) ->
        case LemonCore.Secrets.resolve(provider_cfg[:api_key_secret], env_fallback: true) do
          {:ok, value, _source} when is_binary(value) and value != "" ->
            resolve_secret_api_key(provider_cfg[:api_key_secret], value)

          {:error, reason} ->
            raise "#{game_name} sim could not resolve #{provider_name} credentials: #{inspect(reason)}"
        end

      token = resolve_default_provider_secret(provider_name) ->
        token

      true ->
        raise "#{game_name} sim requires configured credentials for #{provider_name}"
    end
  end

  @doc """
  Resolves a model spec string into a Model struct.
  """
  def resolve_model_spec(provider, model_spec) when is_binary(model_spec) do
    trimmed = String.trim(model_spec)

    cond do
      trimmed == "" ->
        nil

      String.contains?(trimmed, ":") ->
        case String.split(trimmed, ":", parts: 2) do
          [provider_name, model_id] -> lookup_model(provider_name, model_id)
          _ -> nil
        end

      String.contains?(trimmed, "/") ->
        case String.split(trimmed, "/", parts: 2) do
          [provider_name, model_id] -> lookup_model(provider_name, model_id)
          _ -> lookup_model(provider, trimmed)
        end

      true ->
        lookup_model(provider, trimmed)
    end
  end

  def resolve_model_spec(_provider, _model_spec), do: nil

  def lookup_model(nil, model_id), do: LemonAi.Models.find_by_id(model_id)
  def lookup_model("", model_id), do: LemonAi.Models.find_by_id(model_id)

  def lookup_model(provider, model_id)
      when (is_atom(provider) or is_binary(provider)) and is_binary(model_id) do
    case normalize_provider(provider) do
      normalized when is_atom(normalized) -> LemonAi.Models.get_model(normalized, model_id)
      nil -> nil
    end
  end

  def apply_provider_base_url(%LemonAi.Types.Model{} = model, config) do
    provider_name = provider_name(model.provider)
    provider_cfg = Providers.get_provider(config.providers, provider_name)
    base_url = provider_cfg[:base_url]

    if is_binary(base_url) and base_url != "" and base_url != model.base_url do
      %{model | base_url: base_url}
    else
      model
    end
  end

  def provider_name(provider) when is_atom(provider) do
    provider
    |> Atom.to_string()
    |> canonical_provider_name()
  end

  def provider_name(provider) when is_binary(provider), do: canonical_provider_name(provider)

  @doc """
  Resolves a provider name or alias to an atom already present in the model registry.

  Unknown names return `nil`; provider input is never interned as a new BEAM atom.
  """
  @spec normalize_provider(atom() | String.t()) :: atom() | nil
  def normalize_provider(provider_name) when is_atom(provider_name) do
    if provider_name in LemonAi.Models.get_providers() do
      provider_name
    else
      provider_name |> Atom.to_string() |> normalize_provider()
    end
  end

  def normalize_provider(provider_name) when is_binary(provider_name) do
    canonical_name =
      provider_name
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")
      |> canonical_provider_name()

    Enum.find(LemonAi.Models.get_providers(), fn provider ->
      provider_name(provider) == canonical_name
    end)
  end

  def normalize_provider(_provider_name), do: nil

  defp canonical_provider_name(provider_name) when is_binary(provider_name) do
    normalized =
      provider_name
      |> String.trim()
      |> String.downcase()

    Map.get(@provider_aliases, normalized, normalized)
  end

  defp resolve_secret_api_key(secret_name, secret_value)
       when is_binary(secret_name) and is_binary(secret_value) do
    case LemonAi.Auth.OAuthSecretResolver.resolve_api_key_from_secret(
           secret_name,
           secret_value
         ) do
      {:ok, resolved_api_key} when is_binary(resolved_api_key) and resolved_api_key != "" ->
        resolved_api_key

      :ignore ->
        secret_value

      {:error, _reason} ->
        secret_value
    end
  end

  defp resolve_default_provider_secret(provider_name) do
    secret_name = "llm_#{String.replace(provider_name, "-", "_")}_api_key"

    case LemonCore.Secrets.resolve(secret_name, env_fallback: true) do
      {:ok, value, _source} when is_binary(value) and value != "" ->
        resolve_secret_api_key(secret_name, value)

      _ ->
        nil
    end
  end

  defp resolve_openai_codex_api_key(provider_cfg) when is_map(provider_cfg) do
    direct_api_key = provider_cfg[:api_key]
    auth_source = provider_cfg[:auth_source]

    cond do
      is_binary(direct_api_key) and direct_api_key != "" ->
        direct_api_key

      true ->
        configured_secret_names =
          case auth_source do
            "oauth" -> [provider_cfg[:oauth_secret], provider_cfg[:api_key_secret]]
            "api_key" -> [provider_cfg[:api_key_secret], provider_cfg[:oauth_secret]]
            _ -> [provider_cfg[:oauth_secret], provider_cfg[:api_key_secret]]
          end

        configured_secret_names
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.find_value(fn secret_name ->
          case LemonCore.Secrets.resolve(secret_name, env_fallback: true) do
            {:ok, value, _source} when is_binary(value) and value != "" ->
              resolve_secret_api_key(secret_name, value)

            _ ->
              nil
          end
        end)
        |> Kernel.||(
          LemonAgent.ModelRuntime.Credentials.resolve_provider_api_key("openai-codex", %{
            "openai-codex" => %{"auth_source" => "oauth"}
          })
        )
    end
  end
end
