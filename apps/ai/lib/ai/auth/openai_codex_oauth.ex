defmodule Ai.Auth.OpenAICodexOAuth do
  @moduledoc """
  Helpers for resolving OpenAI Codex (ChatGPT OAuth) credentials from Lemon's
  encrypted secret store.

  The canonical secret is `llm_openai_codex_api_key`, stored as an OAuth payload:

      %{
        "type" => "onboarding_openai_codex_oauth",
        "access_token" => "...",
        "refresh_token" => "...",
        "expires_at_ms" => 1_234_567_890_000,
        "account_id" => "...",
        ...
      }

  This module can:
  - Decode OAuth payloads from secret values
  - Refresh near-expiry access tokens via `https://auth.openai.com/oauth/token`
  - Persist refreshed payloads back to the same secret name

  It does not load credentials from Codex CLI files/keychain or environment variables.
  """

  require Logger

  alias LemonCore.Secrets

  @token_url "https://auth.openai.com/oauth/token"

  # OpenAI Codex OAuth client id used by Codex CLI (see pi-ai / Codex CLI sources)
  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @default_secret_name "llm_openai_codex_api_key"
  @secret_type "onboarding_openai_codex_oauth"

  # Try to refresh if the token is within 10 minutes of expiry.
  @near_expiry_ms 10 * 60 * 1000

  @type oauth_secret :: %{optional(String.t()) => term()}

  @doc """
  Backward-compatible alias used by some callers.
  """
  @spec get_api_key() :: String.t() | nil
  def get_api_key, do: resolve_access_token()

  @doc """
  Resolve a fresh ChatGPT JWT access token to use for the Codex API.

  Returns `nil` if no credentials are available.
  """
  @spec resolve_access_token() :: String.t() | nil
  def resolve_access_token do
    case Secrets.get(@default_secret_name) do
      {:ok, value} when is_binary(value) ->
        case resolve_api_key_from_secret(@default_secret_name, value) do
          {:ok, access_token} ->
            access_token

          :ignore ->
            non_empty_binary(value)

          {:error, reason} ->
            Logger.debug(
              "OpenAI Codex OAuth secret #{@default_secret_name} could not be resolved: #{inspect(reason)}"
            )

            nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Resolve a usable API key from an encrypted secret value.

  - Returns `:ignore` for non-Codex-OAuth payloads.
  - Returns `{:ok, access_token}` for valid payloads (refreshing/persisting when needed).
  - Returns `{:error, reason}` when payload is Codex OAuth but unusable.
  """
  @spec resolve_api_key_from_secret(String.t(), String.t()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  def resolve_api_key_from_secret(secret_name, secret_value)
      when is_binary(secret_name) and is_binary(secret_value) do
    with {:ok, secret} <- decode_secret(secret_value),
         {:ok, refreshed_secret, changed?} <- ensure_fresh_secret(secret),
         access_token when is_binary(access_token) and access_token != "" <-
           non_empty_binary(refreshed_secret["access_token"]) do
      if changed? do
        persist_secret(secret_name, refreshed_secret)
      end

      {:ok, access_token}
    else
      :not_oauth -> :ignore
      nil -> {:error, :missing_access_token}
      {:error, reason} -> {:error, reason}
    end
  end

  # ============================================================================
  # Freshness / Refresh
  # ============================================================================

  @spec ensure_fresh_secret(oauth_secret()) ::
          {:ok, oauth_secret(), boolean()} | {:error, term()}
  defp ensure_fresh_secret(secret) when is_map(secret) do
    access = non_empty_binary(secret["access_token"])

    if is_nil(access) do
      {:error, :missing_access_token}
    else
      refresh = non_empty_binary(secret["refresh_token"])

      expires_at_ms =
        normalize_expires_ms(
          secret["expires_at_ms"] || secret["expires_at"] || secret["expires"],
          access
        )

      normalized_secret =
        secret
        |> Map.put_new("type", @secret_type)
        |> maybe_put("expires_at_ms", expires_at_ms)

      changed? = normalized_secret != secret

      cond do
        is_integer(expires_at_ms) and near_expiry?(expires_at_ms) and is_binary(refresh) ->
          case refresh_access_token(refresh) do
            {:ok, refreshed} ->
              now = System.system_time(:millisecond)

              refreshed_secret =
                normalized_secret
                |> Map.put("access_token", refreshed.access)
                |> Map.put("refresh_token", refreshed.refresh || refresh)
                |> Map.put("expires_at_ms", refreshed.expires_at_ms)
                |> Map.put("updated_at_ms", now)
                |> Map.put_new("created_at_ms", now)
                |> Map.put_new("type", @secret_type)

              {:ok, refreshed_secret, true}

            {:error, reason} ->
              Logger.warning("OpenAI Codex token refresh failed: #{inspect(reason)}")
              {:error, :refresh_failed}
          end

        is_integer(expires_at_ms) and near_expiry?(expires_at_ms) ->
          {:error, :expired_no_refresh}

        true ->
          {:ok, normalized_secret, changed?}
      end
    end
  end

  defp near_expiry?(expires_at_ms) do
    now = System.system_time(:millisecond)
    now + @near_expiry_ms >= expires_at_ms
  end

  defp refresh_access_token(refresh_token) do
    # Use :httpc directly so unit tests that set Req.Test plugs don't accidentally
    # hijack this request (refresh should not depend on test stubs unless explicitly mocked).
    body =
      URI.encode_query(%{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => @client_id
      })

    headers = [{~c"content-type", ~c"application/x-www-form-urlencoded"}]

    request =
      {String.to_charlist(@token_url), headers, ~c"application/x-www-form-urlencoded", body}

    http_opts = [timeout: 15_000, connect_timeout: 5_000]
    req_opts = [body_format: :binary]

    case LemonCore.Httpc.request(:post, request, http_opts, req_opts) do
      {:ok, {{_http, status, _reason}, _resp_headers, resp_body}} when status in 200..299 ->
        case Jason.decode(resp_body) do
          {:ok, %{"access_token" => access} = payload}
          when is_binary(access) and access != "" ->
            expires_at_ms = expires_at_from_refresh_payload(payload, access)

            {:ok,
             %{
               access: access,
               refresh: non_empty_binary(payload["refresh_token"]),
               expires_at_ms: expires_at_ms
             }}

          {:ok, other} ->
            {:error, {:invalid_response, other}}

          {:error, err} ->
            {:error, {:decode_error, err}}
        end

      {:ok, {{_http, status, _reason}, _resp_headers, resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp expires_at_from_refresh_payload(payload, access_token) do
    case payload["expires_in"] do
      expires_in when is_number(expires_in) and expires_in > 0 ->
        now = System.system_time(:millisecond)
        now + trunc(expires_in * 1000)

      _ ->
        normalize_expires_ms(nil, access_token)
    end
  end

  # ============================================================================
  # JWT helpers
  # ============================================================================

  defp normalize_expires_ms(expires_raw, access_token) do
    jwt_exp_ms = jwt_exp_ms(access_token)
    parsed_exp = parse_exp_ms(expires_raw)

    cond do
      is_integer(jwt_exp_ms) and jwt_exp_ms > 0 ->
        jwt_exp_ms

      is_integer(parsed_exp) and parsed_exp > 0 ->
        parsed_exp

      true ->
        nil
    end
  end

  defp jwt_exp_ms(token) when is_binary(token) do
    with [_h, payload, _s] <- String.split(token, ".", parts: 3),
         {:ok, decoded} <- decode_base64url(payload),
         {:ok, claims} <- Jason.decode(decoded),
         exp when is_number(exp) <- Map.get(claims, "exp"),
         true <- exp > 0 do
      trunc(exp * 1000)
    else
      _ -> nil
    end
  end

  defp decode_base64url(str) do
    normalized =
      str
      |> String.replace("-", "+")
      |> String.replace("_", "/")

    padded =
      case rem(String.length(normalized), 4) do
        0 -> normalized
        2 -> normalized <> "=="
        3 -> normalized <> "="
        _ -> normalized
      end

    Base.decode64(padded)
  end

  defp parse_exp_ms(nil), do: nil

  defp parse_exp_ms(value) when is_integer(value) do
    if value < 946_684_800_000 do
      value * 1000
    else
      value
    end
  end

  defp parse_exp_ms(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {parsed, ""} ->
        parse_exp_ms(parsed)

      _ ->
        case DateTime.from_iso8601(trimmed) do
          {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
          _ -> nil
        end
    end
  end

  defp parse_exp_ms(_), do: nil

  # ============================================================================
  # Secret decoding / persistence
  # ============================================================================

  defp decode_secret(secret_value) when is_binary(secret_value) do
    case Jason.decode(secret_value) do
      {:ok, %{} = decoded} ->
        access_token = non_empty_binary(decoded["access_token"])
        type = non_empty_binary(decoded["type"])

        cond do
          is_nil(access_token) ->
            :not_oauth

          is_binary(type) and type != @secret_type ->
            :not_oauth

          true ->
            {:ok,
             decoded
             |> Map.put("access_token", access_token)
             |> maybe_put("refresh_token", non_empty_binary(decoded["refresh_token"]))
             |> Map.put_new("type", @secret_type)}
        end

      _ ->
        :not_oauth
    end
  end

  defp persist_secret(secret_name, secret) when is_binary(secret_name) and is_map(secret) do
    encoded = Jason.encode!(secret)

    case Secrets.set(secret_name, encoded, provider: @secret_type) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to persist refreshed OpenAI Codex OAuth secret #{secret_name}: #{inspect(reason)}"
        )

        :error
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp non_empty_binary(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_empty_binary(_), do: nil
end
