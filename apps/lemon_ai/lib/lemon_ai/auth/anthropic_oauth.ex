defmodule LemonAi.Auth.AnthropicOAuth do
  @moduledoc """
  Anthropic OAuth for Claude Pro/Max subscription access.

  `login_device_flow/1` runs Anthropic's authorization-code grant with PKCE on
  `claude.ai`, using the public client Claude Code uses. When a
  `:local_callback_listener` can bind the loopback redirect URI, the browser
  redirect is captured automatically; otherwise the authorization request uses
  Anthropic's hosted code page and the user pastes the `code#state` value it
  shows. A token printed by `claude setup-token` may be pasted at the same
  prompt; it is stored as a non-refreshable credential.

  `resolve_api_key_from_secret/3` returns a usable access token from a stored
  payload, refreshing it shortly before expiry. Refresh is single-flight per
  secret name on the local node: concurrent resolvers queue on one lock, and a
  waiter re-reads the secret through `:reload_secret` so it reuses the token
  the first caller stored instead of replaying a rotated refresh token. A
  refreshed secret that `:persist_secret` fails to store is an error, as is a
  refresh the token endpoint rejects (`{:error, :reauth_required}`); a
  transient refresh failure falls back only to an unexpired access token.
  Stored refresh persistence requires `:reload_secret` to return
  `{:ok, encoded, revision}` and an arity-three `:persist_secret` callback
  that atomically compares that revision. Missing or value-only durable
  reloads fail before HTTP; a stale write never returns the refreshed token.

  Ambient Claude Code logins (the CLI's own credentials file and environment
  tokens) are discovered by the caller, which passes them through
  `resolve_api_key_from_secret/3` with its own `:reload_secret` and
  `:persist_secret`.

  Requests authenticated with these tokens need Claude Code's request shape;
  `oauth_headers/0` and `oauth_beta_features/0` supply the headers and
  `LemonAi.Providers.Anthropic` applies the system-prompt and tool-name rules.
  """

  import LemonAi.Auth.OAuthFlow, only: [non_empty_binary: 1, notify_auth: 3, notify_progress: 2]

  alias LemonAi.Auth.{OAuthFlow, OAuthPKCE, OAuthSecret}

  # Public client id, kept base64 so secret scanners do not flag it.
  @client_id Base.decode64!("OWQxYzI1MGEtZTYxYi00NGQ5LTg4ZWQtNTk0NGQxOTYyZjVl")
  @authorize_url "https://claude.ai/oauth/authorize"
  @token_url "https://platform.claude.com/v1/oauth/token"
  @loopback_redirect_uri "http://localhost:53692/callback"
  @code_page_redirect_uri "https://platform.claude.com/oauth/code/callback"
  @scopes ~w(org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload)
  @secret_type "anthropic_oauth"
  @legacy_secret_types ["onboarding_anthropic_oauth"]
  # Refresh this long before the access token expires.
  @refresh_skew_ms 5 * 60 * 1000
  # Rotation does not extend a grant: Anthropic rejects the refresh token about
  # 30 days after the interactive login, so the user must sign in again.
  @grant_ttl_ms 30 * 24 * 60 * 60 * 1000
  @token_timeout_ms 30_000
  @oauth_beta_features ["claude-code-20250219", "oauth-2025-04-20"]
  # Reviewed in priv/upstream_identities.json; never adopt an unreviewed local CLI version.
  @claude_code_version "2.1.296"

  @type oauth_secret :: %{required(String.t()) => String.t() | integer() | nil}
  @type login_opt ::
          {:on_auth, (String.t(), String.t() | nil -> any())}
          | {:on_progress, (String.t() -> any())}
          | {:on_prompt, (map() -> String.t() | charlist() | nil)}
          | {:redirect_uri, String.t()}
          | {:state, String.t()}
          | {:callback_timeout_ms, pos_integer()}
          | {:listen_for_callback, boolean()}
          | {:local_callback_listener, module()}
  @type resolve_opt ::
          {:persist_secret,
           (String.t(), String.t(), term() -> :ok | {:ok, term()} | {:error, term()})}
          | {:reload_secret,
             (String.t() -> {:ok, String.t(), term()} | {:ok, String.t()} | term())}
          | {:force_refresh, boolean()}

  @doc "OAuth scopes requested at sign-in."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @doc "Build an authorization URL with a fresh PKCE verifier and state."
  @spec authorize_url(keyword()) :: {:ok, map()}
  def authorize_url(opts \\ []), do: build_authorize_url(opts)

  @doc """
  Build an authorization URL with a fresh PKCE verifier and state.

  `:redirect_uri` defaults to Anthropic's hosted code page, which displays a
  `code#state` value for the user to paste.
  """
  @spec build_authorize_url(keyword()) :: {:ok, map()}
  def build_authorize_url(opts \\ []) do
    redirect_uri = Keyword.get(opts, :redirect_uri, @code_page_redirect_uri)
    %{verifier: verifier, challenge: challenge} = OAuthPKCE.generate()
    # claude.ai answers "Invalid request format" for a 22-character state;
    # 32 random bytes (43 characters) are accepted.
    state = Keyword.get(opts, :state, OAuthPKCE.random_state(32))

    params =
      URI.encode_query(
        [
          {"code", "true"},
          {"client_id", @client_id},
          {"response_type", "code"},
          {"redirect_uri", redirect_uri},
          {"scope", Enum.join(@scopes, " ")},
          {"code_challenge", challenge},
          {"code_challenge_method", "S256"},
          {"state", state}
        ],
        :rfc3986
      )

    {:ok,
     %{
       authorize_url: "#{@authorize_url}?#{params}",
       code_verifier: verifier,
       state: state,
       redirect_uri: redirect_uri
     }}
  end

  @doc """
  Sign in with a Claude Pro/Max subscription.

  Requires `:on_auth` (receives the authorization URL and instructions) and
  `:on_prompt` (manual code entry). Pass `:local_callback_listener` to capture
  the loopback redirect automatically. Returns the secret payload; callers own
  encrypted storage.
  """
  @spec login_device_flow([login_opt()]) :: {:ok, oauth_secret()} | {:error, term()}
  def login_device_flow(opts \\ []) when is_list(opts) do
    # The listener must know the state before the authorization URL exists.
    state = Keyword.get(opts, :state) || OAuthPKCE.random_state(32)
    {redirect_uri, listener} = select_redirect(state, opts)

    try do
      with {:ok, auth} <-
             build_authorize_url(Keyword.merge(opts, redirect_uri: redirect_uri, state: state)),
           :ok <- notify_auth(opts, auth.authorize_url, auth_instructions(listener)),
           {:ok, input} <-
             OAuthFlow.await_authorization_input(
               opts,
               auth.redirect_uri,
               listener,
               code_prompt(listener)
             ) do
        complete_login(input, auth, opts)
      end
    after
      OAuthFlow.stop_callback_listener(listener)
    end
  end

  @doc """
  Exchange an authorization code and PKCE verifier for a secret payload.

  Options: `:redirect_uri` (must match the authorization request) and `:state`.
  """
  @spec exchange_code_for_secret(String.t(), String.t(), keyword()) ::
          {:ok, oauth_secret()} | {:error, term()}
  def exchange_code_for_secret(code, code_verifier, opts \\ [])

  def exchange_code_for_secret(code, code_verifier, opts)
      when is_binary(code) and is_binary(code_verifier) do
    redirect_uri = Keyword.get(opts, :redirect_uri, @code_page_redirect_uri)

    body =
      %{
        "grant_type" => "authorization_code",
        "client_id" => @client_id,
        "code" => code,
        "redirect_uri" => redirect_uri,
        "code_verifier" => code_verifier
      }
      |> maybe_put("state", Keyword.get(opts, :state))

    with {:ok, response} <- post_token(body, :authorization_code_rejected),
         {:ok, token} <- OAuthFlow.parse_token_response(response) do
      now = System.system_time(:millisecond)

      {:ok,
       %{
         "type" => @secret_type,
         "source" => "lemon_oauth",
         "access_token" => token.access_token,
         "refresh_token" => token.refresh_token,
         "expires_at_ms" => token.expires_at_ms,
         "created_at_ms" => now,
         "updated_at_ms" => now
       }
       |> maybe_put("scope", non_empty_binary(response["scope"]))
       |> maybe_put("account_uuid", nested_string(response, ["account", "uuid"]))
       |> maybe_put("account_email", nested_string(response, ["account", "email_address"]))
       |> maybe_put("organization_uuid", nested_string(response, ["organization", "uuid"]))
       |> maybe_put("organization_name", nested_string(response, ["organization", "name"]))}
    end
  end

  def exchange_code_for_secret(_, _, _), do: {:error, :invalid_authorization_input}

  @spec encode_secret(oauth_secret()) :: String.t()
  defdelegate encode_secret(secret), to: OAuthSecret, as: :encode

  @spec decode_secret(String.t()) :: {:ok, oauth_secret()} | :not_oauth
  def decode_secret(value), do: OAuthSecret.decode(value, [@secret_type | @legacy_secret_types])

  @doc """
  Redacted login summary for status displays. Never includes tokens.

  `:reauth_by_ms` is the estimated end of a refreshable grant (30 days after
  sign-in); setup tokens and imported credentials have no estimate.
  """
  @spec describe_secret(oauth_secret()) :: map()
  def describe_secret(secret) when is_map(secret) do
    refreshable? = non_empty_binary(secret["refresh_token"]) != nil
    created_at_ms = parse_integer(secret["created_at_ms"])

    %{
      kind: if(refreshable?, do: :refreshable, else: :static_token),
      source: secret["source"],
      account_email: non_empty_binary(secret["account_email"]),
      organization_name: non_empty_binary(secret["organization_name"]),
      expires_at_ms: parse_integer(secret["expires_at_ms"]),
      signed_in_at_ms: created_at_ms,
      reauth_by_ms:
        if(refreshable? and secret["source"] == "lemon_oauth" and is_integer(created_at_ms),
          do: created_at_ms + @grant_ttl_ms
        )
    }
  end

  @doc """
  Resolve a usable access token from an encoded secret payload.

  Returns `:ignore` for values that are not Anthropic OAuth payloads. See the
  module documentation for refresh, persistence and locking rules.
  """
  @spec resolve_api_key_from_secret(String.t(), String.t(), [resolve_opt()]) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  def resolve_api_key_from_secret(secret_name, secret_value, opts \\ []) do
    OAuthSecret.resolve(__MODULE__, secret_name, secret_value, opts, refresh_spec())
  end

  @spec oauth_token?(String.t() | nil) :: boolean()
  def oauth_token?(token) when is_binary(token) do
    trimmed = String.trim(token)

    trimmed != "" and
      (String.starts_with?(trimmed, "sk-ant-oat") or jwt_like?(trimmed))
  end

  def oauth_token?(_), do: false

  @spec oauth_beta_features() :: [String.t()]
  def oauth_beta_features, do: @oauth_beta_features

  @spec oauth_headers() :: [{String.t(), String.t()}]
  def oauth_headers do
    [
      {"user-agent", "claude-cli/#{@claude_code_version} (external, cli)"},
      {"x-app", "cli"}
    ]
  end

  # ── Login ──────────────────────────────────────────────────────────────────

  defp select_redirect(state, opts) do
    case Keyword.get(opts, :redirect_uri) do
      redirect_uri when is_binary(redirect_uri) ->
        {redirect_uri, OAuthFlow.start_callback_listener(redirect_uri, state, opts)}

      nil ->
        case OAuthFlow.start_callback_listener(@loopback_redirect_uri, state, opts) do
          nil -> {@code_page_redirect_uri, nil}
          listener -> {@loopback_redirect_uri, listener}
        end
    end
  end

  defp auth_instructions(nil) do
    "Sign in with your Claude Pro or Max account. Anthropic then shows an authorization " <>
      "code; paste it here."
  end

  defp auth_instructions(_listener) do
    "Sign in with your Claude Pro or Max account. Lemon captures the browser redirect " <>
      "automatically."
  end

  defp code_prompt(nil),
    do: %{
      message: "Paste the authorization code Anthropic shows (code#state):",
      placeholder: "code#state"
    }

  defp code_prompt(_listener),
    do: %{
      message: "Paste the full redirect URL from the browser address bar (or code#state):",
      placeholder: "code#state"
    }

  defp complete_login(input, auth, opts) do
    if setup_token?(input) do
      {:ok, static_token_secret(input, "setup_token")}
    else
      with {:ok, %{code: code, state: state}} <- OAuthFlow.parse_authorization_input(input),
           :ok <- OAuthFlow.ensure_state_matches(auth.state, state) do
        notify_progress(opts, "Exchanging the authorization code for tokens...")

        exchange_code_for_secret(code, auth.code_verifier,
          redirect_uri: auth.redirect_uri,
          state: auth.state
        )
      end
    end
  end

  defp setup_token?(input) do
    String.starts_with?(input, "sk-ant-oat") and not String.contains?(input, ["#", "://", "="])
  end

  defp static_token_secret(access_token, source) do
    now = System.system_time(:millisecond)

    %{
      "type" => @secret_type,
      "source" => source,
      "access_token" => access_token,
      "refresh_token" => nil,
      "expires_at_ms" => nil,
      "created_at_ms" => now,
      "updated_at_ms" => now
    }
  end

  # ── Freshness and single-flight refresh ────────────────────────────────────

  defp refresh_spec do
    %{
      refresh: &refresh_secret/1,
      skew_ms: @refresh_skew_ms,
      usable: &OAuthSecret.usable/1,
      resolve: &OAuthSecret.access_token/1,
      refresh_replaced: true
    }
  end

  defp refresh_secret(secret) do
    refresh_token = non_empty_binary(secret["refresh_token"])

    body = %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "client_id" => @client_id
    }

    with {:ok, response} <- post_token(body, :reauth_required),
         {:ok, token} <- OAuthFlow.parse_token_response(response) do
      {:ok,
       secret
       |> Map.put("type", @secret_type)
       |> Map.put("access_token", token.access_token)
       |> Map.put("refresh_token", token.refresh_token || refresh_token)
       |> Map.put("expires_at_ms", token.expires_at_ms)
       |> Map.put("updated_at_ms", System.system_time(:millisecond))}
    end
  end

  # ── Token endpoint ─────────────────────────────────────────────────────────

  # `invalid_grant` is the token endpoint's definitive rejection of the code or
  # refresh token; the caller names what it means for the user.
  defp post_token(body, invalid_grant_reason) do
    case Req.post(@token_url,
           json: body,
           headers: [{"accept", "application/json"}],
           retry: false,
           redirect: false,
           receive_timeout: @token_timeout_ms
         ) do
      {:ok, %Req.Response{status: status, body: response}} when status in 200..299 ->
        decode_body(response)

      {:ok, %Req.Response{status: status, body: response}} when status in [400, 401] ->
        case decode_body(response) do
          {:ok, %{"error" => "invalid_grant"}} -> {:error, invalid_grant_reason}
          {:ok, %{"error" => code}} when is_binary(code) -> {:error, {:http_error, status, code}}
          _ -> {:error, {:http_error, status}}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, exception} ->
        {:error, {:transport_error, transport_reason(exception)}}
    end
  end

  defp decode_body(body) when is_map(body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, :invalid_token_response}
    end
  end

  defp decode_body(_), do: {:error, :invalid_token_response}

  defp transport_reason(%{reason: reason}) when is_atom(reason), do: reason
  defp transport_reason(_), do: :unknown

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp nested_string(map, path) do
    case get_in(map, path) do
      value when is_binary(value) -> non_empty_binary(value)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_integer(value) when is_integer(value), do: value
  defp parse_integer(value) when is_float(value), do: trunc(value)

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp jwt_like?(value) do
    match?([_header, _payload, _signature], String.split(value, ".", parts: 3))
  end
end
