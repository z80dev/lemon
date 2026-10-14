defmodule LemonAi.Auth.OAuthSecretResolver do
  @moduledoc """
  Provider-agnostic OAuth secret resolver.

  Dispatches provider-specific OAuth secret payloads to the matching auth helper
  and returns a usable API key value.
  """

  @resolvers [
    LemonAi.Auth.AnthropicOAuth,
    LemonAi.Auth.GitHubCopilotOAuth,
    LemonAi.Auth.GoogleAntigravityOAuth,
    LemonAi.Auth.GoogleGeminiCliOAuth,
    LemonAi.Auth.KimiCodeOAuth,
    LemonAi.Auth.OpenAICodexOAuth,
    LemonAi.Auth.XAIOAuth
  ]

  @spec resolve_api_key_from_secret(String.t(), String.t()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  def resolve_api_key_from_secret(secret_name, secret_value, opts \\ [])

  def resolve_api_key_from_secret(secret_name, secret_value, opts)
      when is_binary(secret_name) and is_binary(secret_value) do
    Enum.reduce_while(@resolvers, :ignore, fn resolver, _acc ->
      case resolver.resolve_api_key_from_secret(secret_name, secret_value, opts) do
        :ignore ->
          {:cont, :ignore}

        {:ok, _api_key} = ok ->
          {:halt, ok}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  def resolve_api_key_from_secret(_, _, _), do: {:error, :invalid_secret_value}

  @doc false
  def with_refresh_lock(resolver, secret_name, secret, opts, resolve) do
    :global.trans(
      {{__MODULE__, resolver, secret_name}, self()},
      fn ->
        with {:ok, latest, opts} <- reload_secret(resolver, secret_name, secret, opts) do
          # The caller may have waited while another session rotated this login.
          # Its earlier rejection does not apply to the replacement token.
          opts =
            if latest["access_token"] != secret["access_token"],
              do: Keyword.put(opts, :force_refresh, false),
              else: opts

          resolve.(latest, opts)
        end
      end,
      [node()]
    )
  end

  @doc false
  def reload_secret(resolver, secret_name, stale, opts) do
    reload_secret(secret_name, stale, opts, &resolver.decode_secret/1, &resolver.encode_secret/1)
  end

  @doc false
  def reload_secret(secret_name, stale, opts, decode, encode) do
    persistent? = not is_nil(Keyword.get(opts, :persist_secret))

    loaded =
      case Keyword.get(opts, :reload_secret) do
        reload when is_function(reload, 1) -> reload.(secret_name)
        nil when not persistent? -> {:ok, encode.(stale)}
        _ -> {:error, :invalid_reload_callback}
      end

    case loaded do
      {:ok, encoded, revision} when is_binary(encoded) and not is_nil(revision) ->
        decode_reloaded(decode, encoded, revision, opts)

      {:ok, encoded} when is_binary(encoded) and not persistent? ->
        decode_reloaded(decode, encoded, encoded, opts)

      {:error, reason} when reason in [:not_found, :expired] ->
        {:error, :oauth_secret_missing}

      _ ->
        {:error, :oauth_secret_reload_failed}
    end
  rescue
    _ -> {:error, :oauth_secret_reload_failed}
  catch
    _, _ -> {:error, :oauth_secret_reload_failed}
  end

  defp decode_reloaded(decode, encoded, revision, opts) do
    case decode.(encoded) do
      {:ok, latest} -> {:ok, latest, Keyword.put(opts, :oauth_secret_revision, revision)}
      :not_oauth -> {:error, :oauth_secret_replaced}
      _ -> {:error, :oauth_secret_replaced}
    end
  end

  @doc false
  def persist_secret(secret_name, encoded, opts) do
    case Keyword.get(opts, :persist_secret) do
      nil ->
        :ok

      callback when is_function(callback, 3) ->
        case callback.(secret_name, encoded, Keyword.fetch!(opts, :oauth_secret_revision)) do
          :ok -> :ok
          {:ok, _metadata} -> :ok
          {:error, :stale_revision} -> {:error, :oauth_secret_changed}
          _ -> {:error, :oauth_secret_persistence_failed}
        end

      _ ->
        {:error, :oauth_secret_persistence_failed}
    end
  rescue
    _ -> {:error, :oauth_secret_persistence_failed}
  catch
    _, _ -> {:error, :oauth_secret_persistence_failed}
  end
end
