defmodule LemonAi.Auth.OAuthSecret do
  @moduledoc false

  alias LemonAi.Auth.OAuthFlow

  def encode(secret) when is_map(secret), do: Jason.encode!(secret)

  def decode(value, types) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{"type" => type} = secret} ->
        if type in types, do: {:ok, secret}, else: :not_oauth

      _ ->
        :not_oauth
    end
  end

  def decode(_, _), do: :not_oauth

  def resolve(resolver, name, value, opts, spec)
      when is_binary(name) and is_binary(value) do
    case resolver.decode_secret(value) do
      {:ok, secret} ->
        spec =
          Map.merge(spec, %{
            lock: resolver,
            decode: &resolver.decode_secret/1,
            encode: &resolver.encode_secret/1
          })

        with {:ok, fresh} <- OAuthFlow.ensure_fresh(name, secret, opts, spec) do
          case Map.get(spec, :resolve) do
            nil -> {:ok, fresh["access_token"]}
            resolve -> resolve.(fresh)
          end
        end

      :not_oauth ->
        :ignore
    end
  end

  def resolve(_, _, _, _, _), do: {:error, :invalid_secret_value}

  def access_token(secret) do
    case OAuthFlow.non_empty_binary(secret["access_token"]) do
      nil -> {:error, :missing_access_token}
      token -> {:ok, token}
    end
  end

  def project_key(secret, project_id, error) do
    with {:ok, token} <- access_token(secret),
         project_id when is_binary(project_id) and project_id != "" <- project_id do
      {:ok, Jason.encode!(%{"token" => token, "projectId" => project_id})}
    else
      _ -> {:error, error}
    end
  end

  # Legacy providers check expiry before formatting their provider-specific key.
  def usable(secret) do
    case OAuthFlow.parse_integer(secret["expires_at_ms"]) do
      ms when is_integer(ms) ->
        if ms <= System.system_time(:millisecond),
          do: {:error, :expired_access_token},
          else: {:ok, secret}

      _ ->
        {:ok, secret}
    end
  end

  def build(type, token, fields) do
    now = System.system_time(:millisecond)

    Map.merge(
      %{
        "type" => type,
        "access_token" => token.access_token,
        "refresh_token" => token.refresh_token,
        "expires_at_ms" => token.expires_at_ms,
        "created_at_ms" => now,
        "updated_at_ms" => now
      },
      fields
    )
  end

  # These providers predate OAuthFlow's credential-free token parser. Preserve
  # their error terms and stored expiry skew while sharing the parsing itself.
  def parse_token_response(data, skew_ms \\ 0, include_error_data? \\ false)

  def parse_token_response(data, skew_ms, include_error_data?) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, decoded} when is_map(decoded) ->
        parse_token_response(decoded, skew_ms, include_error_data?)

      _ ->
        token_error(:invalid_token_response, data, include_error_data?)
    end
  end

  def parse_token_response(data, skew_ms, include_error_data?) when is_map(data) do
    case OAuthFlow.parse_token_response(data) do
      {:ok, token} ->
        {:ok, %{token | expires_at_ms: token.expires_at_ms - skew_ms}}

      {:error, :missing_access_token} ->
        token_error(:invalid_token_response, data, include_error_data?)

      {:error, reason} ->
        token_error(reason, data, include_error_data?)
    end
  end

  def parse_token_response(data, _skew_ms, include_error_data?),
    do: token_error(:invalid_token_response, data, include_error_data?)

  defp token_error(reason, data, true), do: {:error, {reason, data}}
  defp token_error(reason, _data, false), do: {:error, reason}
end
