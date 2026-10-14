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
        with {:ok, latest} <- reload_secret(resolver, secret_name, secret, opts) do
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

  defp reload_secret(resolver, secret_name, stale, opts) do
    case Keyword.get(opts, :reload_secret) do
      reload when is_function(reload, 1) ->
        with {:ok, encoded} when is_binary(encoded) <- reload.(secret_name),
             {:ok, latest} <- resolver.decode_secret(encoded) do
          {:ok, latest}
        else
          :not_oauth -> {:error, :oauth_secret_replaced}
          _ -> {:error, :oauth_secret_missing}
        end

      _ ->
        {:ok, stale}
    end
  end
end
