defmodule LemonAi.Auth.XAIOAuth do
  @moduledoc """
  xAI Grok OAuth (SuperGrok or X Premium+) through the device authorization grant.

  `login_device_flow/1` discovers xAI's token endpoint from its OpenID
  configuration, shows a verification URL and user code through `:on_auth`,
  polls until the user approves, and returns a refreshable secret payload. The
  access token is an ordinary bearer for `https://api.x.ai/v1`, so the payload
  is stored for the existing `xai` provider.

  The discovered token endpoint receives every future refresh token, so it must
  be HTTPS on `x.ai` or a subdomain, on port 443 without URL credentials or a
  fragment. It is stored in the payload and validated again before each refresh.

  `resolve_api_key_from_secret/3` refreshes five minutes before expiry or on
  `force_refresh: true`; see `LemonAi.Auth.OAuthFlow` for locking and
  persistence. Tests and local fakes may override `:discovery_url`,
  `:device_url`, `:token_url` (used verbatim) and `:userinfo_url`, and pass
  `:req_options`.
  """

  alias LemonAi.Auth.OAuthFlow

  @client_id "b1a00492-073a-47ea-816f-4c329264a828"
  @scopes ~w(openid profile email offline_access grok-cli:access api:access)
  @discovery_url "https://auth.x.ai/.well-known/openid-configuration"
  @device_url "https://auth.x.ai/oauth2/device/code"
  @userinfo_url "https://auth.x.ai/oauth2/userinfo"
  @secret_type "xai_oauth"
  @refresh_skew_ms 5 * 60 * 1000
  @accept [{"accept", "application/json"}]

  @type oauth_secret :: %{required(String.t()) => String.t() | integer() | nil}

  @doc "OAuth scopes requested at sign-in."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @doc """
  Sign in with the device authorization grant.

  Requires `:on_auth` (verification URL and `Enter code: …` instructions).
  Optional: `:on_progress`, `:sleep`, and the URL/`:req_options` overrides in
  the module documentation. Returns the secret payload; callers own storage.
  """
  @spec login_device_flow(keyword()) :: {:ok, oauth_secret()} | {:error, term()}
  def login_device_flow(opts \\ []) when is_list(opts) do
    with {:ok, token_url} <- token_endpoint(opts),
         :ok <- OAuthFlow.notify_progress(opts, "Requesting xAI device authorization..."),
         {:ok, response} <-
           OAuthFlow.request(
             Keyword.get(opts, :device_url, @device_url),
             [
               form: %{"client_id" => @client_id, "scope" => Enum.join(@scopes, " ")},
               headers: @accept
             ],
             opts
           ),
         {:ok, device} <- OAuthFlow.parse_device_response(response),
         :ok <-
           OAuthFlow.notify_auth(
             opts,
             device.verification_uri_complete || device.verification_uri,
             "Enter code: #{device.user_code}"
           ),
         :ok <- OAuthFlow.notify_progress(opts, "Waiting for device authorization..."),
         {:ok, body} <- poll(token_url, device, opts),
         {:ok, token} <- OAuthFlow.parse_token_response(body) do
      now = System.system_time(:millisecond)

      secret =
        %{
          "type" => @secret_type,
          "access_token" => token.access_token,
          "refresh_token" => token.refresh_token,
          "expires_at_ms" => token.expires_at_ms,
          "token_endpoint" => token_url,
          "created_at_ms" => now,
          "updated_at_ms" => now
        }
        |> put_present("account_id", access_token_subject(token.access_token))
        |> apply_userinfo(opts)

      {:ok, secret}
    end
  end

  defp poll(token_url, device, opts) do
    body = %{
      "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
      "client_id" => @client_id,
      "device_code" => device.device_code
    }

    OAuthFlow.poll_device_token(
      fn ->
        case OAuthFlow.request(token_url, [form: body, headers: @accept], opts) do
          {:ok, response} -> OAuthFlow.classify_device_token_response(response)
          {:error, _} = error -> error
        end
      end,
      interval_s: device.interval,
      expires_in_s: device.expires_in,
      deadline_ms: device.expires_at_ms,
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1)
    )
  end

  @doc "Encode a secret payload for storage."
  @spec encode_secret(oauth_secret()) :: String.t()
  def encode_secret(secret) when is_map(secret), do: Jason.encode!(secret)

  @doc "Decode a stored xAI OAuth payload."
  @spec decode_secret(term()) :: {:ok, oauth_secret()} | :not_oauth
  def decode_secret(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{"type" => @secret_type} = secret} -> {:ok, secret}
      _ -> :not_oauth
    end
  end

  def decode_secret(_), do: :not_oauth

  @doc "Redacted login summary for status displays. Never includes tokens."
  @spec describe_secret(oauth_secret()) :: map()
  def describe_secret(secret) when is_map(secret) do
    %{
      kind:
        if(OAuthFlow.non_empty_binary(secret["refresh_token"]),
          do: :refreshable,
          else: :static_token
        ),
      account_email: OAuthFlow.non_empty_binary(secret["account_email"]),
      expires_at_ms: OAuthFlow.parse_integer(secret["expires_at_ms"]),
      signed_in_at_ms: OAuthFlow.parse_integer(secret["created_at_ms"])
    }
  end

  @doc """
  Resolve a usable access token from a stored payload; `:ignore` for other values.

  Options: `:persist_secret`, `:reload_secret`, `:force_refresh`, plus the
  `:token_url`/`:discovery_url`/`:req_options` overrides.
  Stored refreshes capture the revision through `:reload_secret` and pass it
  to arity-three `:persist_secret`; a stale write returns
  `{:error, :oauth_secret_changed}` without exposing the refreshed token.
  """
  @spec resolve_api_key_from_secret(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  def resolve_api_key_from_secret(secret_name, secret_value, opts \\ [])

  def resolve_api_key_from_secret(secret_name, secret_value, opts)
      when is_binary(secret_name) and is_binary(secret_value) do
    case decode_secret(secret_value) do
      {:ok, secret} ->
        spec = %{
          lock: __MODULE__,
          decode: &decode_secret/1,
          encode: &encode_secret/1,
          refresh: &refresh_secret(&1, opts),
          skew_ms: @refresh_skew_ms
        }

        with {:ok, fresh} <- OAuthFlow.ensure_fresh(secret_name, secret, opts, spec) do
          {:ok, fresh["access_token"]}
        end

      :not_oauth ->
        :ignore
    end
  end

  def resolve_api_key_from_secret(_, _, _), do: {:error, :invalid_secret_value}

  @doc """
  Validate an HTTPS x.ai endpoint on port 443 without URL credentials or a fragment.

  The complete authority must contain only a DNS hostname and an optional numeric
  port; `URI.parse/1` alone can discard malformed port suffixes.
  """
  @spec validate_endpoint(term()) :: {:ok, String.t()} | {:error, :invalid_xai_endpoint}
  def validate_endpoint(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{
        scheme: "https",
        host: host,
        authority: authority,
        port: 443,
        userinfo: nil,
        fragment: nil
      }
      when is_binary(host) and is_binary(authority) ->
        authority = String.downcase(authority)

        if Regex.match?(
             ~r/\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*x\.ai(?::[0-9]+)?\z/,
             authority
           ),
           do: {:ok, url},
           else: {:error, :invalid_xai_endpoint}

      _ ->
        {:error, :invalid_xai_endpoint}
    end
  rescue
    _ -> {:error, :invalid_xai_endpoint}
  end

  def validate_endpoint(_), do: {:error, :invalid_xai_endpoint}

  # ── Refresh ────────────────────────────────────────────────────────────────

  defp refresh_secret(secret, opts) do
    refresh_token = OAuthFlow.non_empty_binary(secret["refresh_token"])

    body = %{
      "grant_type" => "refresh_token",
      "client_id" => @client_id,
      "refresh_token" => refresh_token
    }

    with {:ok, token_url} <- refresh_endpoint(secret, opts),
         {:ok, response} <-
           OAuthFlow.request(token_url, [form: body, headers: @accept], opts),
         {:ok, token} <- OAuthFlow.refresh_response(response, refresh_token) do
      {:ok,
       secret
       |> Map.put("access_token", token.access_token)
       |> Map.put("refresh_token", token.refresh_token)
       |> Map.put("expires_at_ms", token.expires_at_ms)
       |> Map.put("token_endpoint", token_url)
       |> Map.put("updated_at_ms", System.system_time(:millisecond))
       |> put_present("account_id", access_token_subject(token.access_token))}
    end
  end

  # An explicit override wins; otherwise the stored endpoint must still pass
  # validation, else it is discovered again.
  defp refresh_endpoint(secret, opts) do
    case Keyword.get(opts, :token_url) do
      url when is_binary(url) ->
        {:ok, url}

      _ ->
        case validate_endpoint(secret["token_endpoint"]) do
          {:ok, url} -> {:ok, url}
          {:error, _} -> token_endpoint(opts)
        end
    end
  end

  # ── Discovery and identity ─────────────────────────────────────────────────

  defp token_endpoint(opts) do
    case Keyword.get(opts, :token_url) do
      url when is_binary(url) ->
        {:ok, url}

      _ ->
        discovery_url = Keyword.get(opts, :discovery_url, @discovery_url)

        case OAuthFlow.request(discovery_url, [method: :get, headers: @accept], opts) do
          {:ok, %{status: 200, body: %{"token_endpoint" => url}}} when is_binary(url) ->
            validate_endpoint(String.trim(url))

          {:ok, %{status: 200}} ->
            {:error, :invalid_xai_discovery_response}

          {:ok, %{status: status}} ->
            {:error, {:xai_discovery_failed, status}}

          {:error, _} = error ->
            error
        end
    end
  end

  # Identity is optional: a failed userinfo call leaves the fields unset.
  defp apply_userinfo(secret, opts) do
    url = Keyword.get(opts, :userinfo_url, @userinfo_url)
    headers = [{"authorization", "Bearer #{secret["access_token"]}"} | @accept]

    case OAuthFlow.request(url, [method: :get, headers: headers], opts) do
      {:ok, %{status: 200, body: %{} = body}} ->
        secret
        |> put_present("account_id", OAuthFlow.claim(body, ["sub"]))
        |> put_present(
          "account_email",
          body |> OAuthFlow.claim(["email"]) |> then(&(&1 && String.downcase(&1)))
        )

      _ ->
        secret
    end
  end

  defp access_token_subject(access_token) do
    access_token |> OAuthFlow.jwt_claims() |> OAuthFlow.claim(["sub"])
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
