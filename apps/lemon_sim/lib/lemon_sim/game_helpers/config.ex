defmodule LemonSim.GameHelpers.Config do
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
  """
  def resolve_configured_model!(config, game_name \\ "game") do
    provider = config.agent.default_provider
    model_spec = config.agent.default_model

    case resolve_model_spec(provider, model_spec) do
      %Ai.Types.Model{} = model ->
        apply_provider_base_url(model, config)

      nil ->
        raise """
        #{game_name} sim requires a valid default model.
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

  def lookup_model(nil, model_id), do: Ai.Models.find_by_id(model_id)
  def lookup_model("", model_id), do: Ai.Models.find_by_id(model_id)

  def lookup_model(provider, model_id) when is_binary(provider) and is_binary(model_id) do
    normalized = normalize_provider(provider)

    Ai.Models.get_model(normalized, model_id) ||
      Ai.Models.get_model(String.to_atom(String.trim(provider)), model_id)
  end

  def apply_provider_base_url(%Ai.Types.Model{} = model, config) do
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

  def normalize_provider(provider_name) do
    provider_name
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> canonical_provider_name()
    |> String.to_atom()
  end

  defp canonical_provider_name(provider_name) when is_binary(provider_name) do
    normalized =
      provider_name
      |> String.trim()
      |> String.downcase()

    Map.get(@provider_aliases, normalized, normalized)
  end

  defp resolve_secret_api_key(secret_name, secret_value)
       when is_binary(secret_name) and is_binary(secret_value) do
    case LemonAiRuntime.Auth.OAuthSecretResolver.resolve_api_key_from_secret(secret_name, secret_value) do
      {:ok, resolved_api_key} when is_binary(resolved_api_key) and resolved_api_key != "" ->
        resolved_api_key

      :ignore ->
        secret_value

      {:error, _reason} ->
        secret_value
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
        |> Kernel.||(LemonAiRuntime.Auth.OpenAICodexOAuth.resolve_access_token())
    end
  end
end
