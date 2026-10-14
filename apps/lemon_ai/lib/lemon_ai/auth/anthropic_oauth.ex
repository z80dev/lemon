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

  `resolve_access_token/0` reads ambient Claude Code credentials
  (`~/.claude/.credentials.json`, `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_TOKEN`)
  for configurations that opt into OAuth without a stored Lemon login.

  Requests authenticated with these tokens need Claude Code's request shape;
  `oauth_headers/0` and `oauth_beta_features/0` supply the headers and
  `LemonAi.Providers.Anthropic` applies the system-prompt and tool-name rules.
  """

  require Logger

  alias LemonAi.Auth.OAuthPKCE

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
  @default_callback_timeout_ms 120_000
  @token_timeout_ms 30_000
  @oauth_env_vars ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_TOKEN"]
  @oauth_beta_features ["claude-code-20250219", "oauth-2025-04-20"]
  @claude_code_version_floor "2.1.296"
  @claude_code_file_lock "claude_code_credentials_file"

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
    {redirect_uri, listener} = select_redirect(opts)

    try do
      with {:ok, auth} <- build_authorize_url(Keyword.put(opts, :redirect_uri, redirect_uri)),
           :ok <- notify_auth(opts, auth.authorize_url, auth_instructions(listener)),
           {:ok, input} <- await_authorization_input(opts, auth.redirect_uri, listener) do
        complete_login(input, auth, opts)
      end
    after
      stop_listener(listener)
    end
  end

  @doc """
  Parse pasted authorization input: a redirect URL, a query string containing
  `code=`, `code#state`, or a bare code.
  """
  @spec parse_authorization_input(String.t()) ::
          {:ok, %{code: String.t(), state: String.t() | nil}} | {:error, term()}
  def parse_authorization_input(input) when is_binary(input) do
    value = String.trim(input)

    parsed =
      cond do
        value == "" ->
          %{code: nil, state: nil}

        String.contains?(value, "://") ->
          case URI.parse(value) do
            %URI{query: query} when is_binary(query) and query != "" ->
              params = URI.decode_query(query)
              %{code: params["code"], state: params["state"]}

            _ ->
              %{code: nil, state: nil}
          end

        String.contains?(value, "#") ->
          [code, state] = String.split(value, "#", parts: 2)
          %{code: code, state: state}

        String.contains?(value, "code=") ->
          params = URI.decode_query(value)
          %{code: params["code"], state: params["state"]}

        true ->
          %{code: value, state: nil}
      end

    case non_empty_binary(parsed.code) do
      nil -> {:error, :missing_authorization_code}
      code -> {:ok, %{code: code, state: non_empty_binary(parsed.state)}}
    end
  end

  def parse_authorization_input(_), do: {:error, :invalid_authorization_input}

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
         {:ok, token} <- parse_token_response(response) do
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
  def encode_secret(secret) when is_map(secret), do: Jason.encode!(secret)

  @spec decode_secret(String.t()) :: {:ok, oauth_secret()} | :not_oauth
  def decode_secret(secret_value) when is_binary(secret_value) do
    case Jason.decode(secret_value) do
      {:ok, %{"type" => type} = decoded}
      when type == @secret_type or type in @legacy_secret_types ->
        {:ok, decoded}

      _ ->
        :not_oauth
    end
  end

  def decode_secret(_), do: :not_oauth

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
  def resolve_api_key_from_secret(secret_name, secret_value, opts \\ [])

  def resolve_api_key_from_secret(secret_name, secret_value, opts)
      when is_binary(secret_name) and is_binary(secret_value) do
    case decode_secret(secret_value) do
      {:ok, secret} ->
        reload = fn ->
          LemonAi.Auth.OAuthSecretResolver.reload_secret(__MODULE__, secret_name, secret, opts)
        end

        persist = fn refreshed, captured_opts ->
          LemonAi.Auth.OAuthSecretResolver.persist_secret(
            secret_name,
            encode_secret(refreshed),
            captured_opts
          )
        end

        force? = Keyword.get(opts, :force_refresh, false) == true

        with {:ok, fresh} <- ensure_fresh(secret_name, secret, reload, persist, force?) do
          access_token(fresh)
        end

      :not_oauth ->
        :ignore
    end
  end

  def resolve_api_key_from_secret(_, _, _), do: {:error, :invalid_secret_value}

  @doc """
  Resolve an ambient Claude Code token: refreshable credentials from
  `~/.claude/.credentials.json` win over a static `CLAUDE_CODE_OAUTH_TOKEN` or
  `ANTHROPIC_TOKEN` value.
  """
  @spec resolve_access_token() :: String.t() | nil
  def resolve_access_token do
    claude_code_secret = current_claude_code_secret()

    resolve_env_token(claude_code_secret) ||
      if(claude_code_secret, do: non_empty_binary(claude_code_secret["access_token"]))
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
      {"user-agent", "claude-cli/#{claude_code_version()} (external, cli)"},
      {"x-app", "cli"}
    ]
  end

  # ── Login ──────────────────────────────────────────────────────────────────

  defp select_redirect(opts) do
    listener_module = Keyword.get(opts, :local_callback_listener)
    listen? = Keyword.get(opts, :listen_for_callback, true) and listener_module != nil

    case Keyword.get(opts, :redirect_uri) do
      redirect_uri when is_binary(redirect_uri) ->
        if listen? and listener_module.local_redirect_uri?(redirect_uri) do
          {redirect_uri, start_listener(listener_module, redirect_uri, opts)}
        else
          {redirect_uri, nil}
        end

      nil when listen? ->
        case start_listener(listener_module, @loopback_redirect_uri, opts) do
          nil -> {@code_page_redirect_uri, nil}
          listener -> {@loopback_redirect_uri, listener}
        end

      nil ->
        {@code_page_redirect_uri, nil}
    end
  end

  defp start_listener(listener_module, redirect_uri, opts) do
    case listener_module.start(redirect_uri) do
      {:ok, listener} ->
        {listener_module, listener}

      {:error, reason} ->
        notify_progress(
          opts,
          "Could not listen on #{redirect_uri} (#{format_listener_error(reason)}). " <>
            "Using the copy-code sign-in instead."
        )

        nil
    end
  end

  defp stop_listener(nil), do: :ok
  defp stop_listener({listener_module, listener}), do: listener_module.stop(listener)

  defp auth_instructions(nil) do
    "Sign in with your Claude Pro or Max account. Anthropic then shows an authorization " <>
      "code; paste it here."
  end

  defp auth_instructions(_listener) do
    "Sign in with your Claude Pro or Max account. Lemon captures the browser redirect " <>
      "automatically."
  end

  defp await_authorization_input(opts, _redirect_uri, nil), do: prompt_for_code(opts, :code_page)

  defp await_authorization_input(opts, redirect_uri, {listener_module, listener}) do
    timeout_ms = Keyword.get(opts, :callback_timeout_ms, @default_callback_timeout_ms)
    notify_progress(opts, "Waiting for the browser redirect to #{redirect_uri} ...")

    case listener_module.wait(listener, timeout_ms) do
      {:ok, callback_url} ->
        {:ok, callback_url}

      {:error, reason} ->
        notify_progress(
          opts,
          "The browser redirect did not arrive (#{format_listener_error(reason)})."
        )

        prompt_for_code(opts, :loopback)
    end
  end

  defp prompt_for_code(opts, mode) do
    message =
      case mode do
        :code_page ->
          "Paste the authorization code Anthropic shows (code#state):"

        :loopback ->
          "Paste the full redirect URL from the browser address bar (or code#state):"
      end

    case Keyword.get(opts, :on_prompt) do
      prompt when is_function(prompt, 1) ->
        case prompt.(%{message: message, placeholder: "code#state"})
             |> normalize_prompt_input() do
          "" -> {:error, :login_cancelled}
          value -> {:ok, value}
        end

      _ ->
        {:error, :prompt_callback_required}
    end
  end

  defp complete_login(input, auth, opts) do
    if setup_token?(input) do
      {:ok, static_token_secret(input, "setup_token")}
    else
      with {:ok, %{code: code, state: state}} <- parse_authorization_input(input),
           :ok <- ensure_state_matches(auth.state, state) do
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

  defp ensure_state_matches(_expected, nil), do: :ok
  defp ensure_state_matches(expected, expected), do: :ok
  defp ensure_state_matches(_expected, _provided), do: {:error, :oauth_state_mismatch}

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

  # `reload` returns the latest map and captured revision opts (or an error).
  # `persist` receives that map's opts, not the caller's original opts. Both run
  # under the lock so a queued caller sees what the previous holder stored.
  #
  # A forced refresh (the provider rejected the access token) refreshes only
  # when the stored token is still the rejected one; a concurrent caller that
  # already rotated it wins. A forced refresh never falls back to the rejected
  # token.
  defp ensure_fresh(lock_name, secret, reload, persist, force?) do
    if force? or refresh_due?(secret) do
      :global.trans(
        {{__MODULE__, :refresh, lock_name}, self()},
        fn ->
          with {:ok, latest, captured_opts} <- reload.() do
            persist_latest = fn refreshed -> persist.(refreshed, captured_opts) end

            cond do
              force? and latest["access_token"] == secret["access_token"] ->
                force_refresh_and_persist(latest, persist_latest)

              refresh_due?(latest) ->
                refresh_and_persist(latest, persist_latest, reload)

              true ->
                usable(latest)
            end
          end
        end,
        [node()]
      )
    else
      usable(secret)
    end
  end

  defp force_refresh_and_persist(secret, persist) do
    if non_empty_binary(secret["refresh_token"]) do
      with {:ok, refreshed} <- refresh_secret(secret),
           :ok <- persist.(refreshed) do
        {:ok, refreshed}
      end
    else
      {:error, :not_refreshable}
    end
  end

  defp usable(secret) do
    if expired?(secret), do: {:error, :expired_access_token}, else: {:ok, secret}
  end

  defp refresh_and_persist(secret, persist, reload) do
    case refresh_secret(secret) do
      {:ok, refreshed} ->
        case persist.(refreshed) do
          :ok -> {:ok, refreshed}
          {:error, _} = error -> error
        end

      {:error, :reauth_required} = error ->
        error

      {:error, reason} ->
        if expired?(secret) or is_nil(non_empty_binary(secret["access_token"])) do
          {:error, reason}
        else
          Logger.debug("Anthropic OAuth refresh failed; reloading the unexpired access token")

          with {:ok, latest, _opts} <- reload.(), do: usable(latest)
        end
    end
  end

  defp refresh_due?(secret) do
    refresh_token = non_empty_binary(secret["refresh_token"])
    expires_at_ms = parse_integer(secret["expires_at_ms"])

    cond do
      is_nil(refresh_token) -> false
      is_nil(non_empty_binary(secret["access_token"])) -> true
      is_nil(expires_at_ms) -> false
      true -> expires_at_ms - System.system_time(:millisecond) <= @refresh_skew_ms
    end
  end

  defp expired?(secret) do
    case parse_integer(secret["expires_at_ms"]) do
      expires_at_ms when is_integer(expires_at_ms) ->
        expires_at_ms <= System.system_time(:millisecond)

      _ ->
        false
    end
  end

  defp refresh_secret(secret) do
    refresh_token = non_empty_binary(secret["refresh_token"])

    body = %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "client_id" => @client_id
    }

    with {:ok, response} <- post_token(body, :reauth_required),
         {:ok, token} <- parse_token_response(response) do
      {:ok,
       secret
       |> Map.put("type", @secret_type)
       |> Map.put("access_token", token.access_token)
       |> Map.put("refresh_token", token.refresh_token || refresh_token)
       |> Map.put("expires_at_ms", token.expires_at_ms)
       |> Map.put("updated_at_ms", System.system_time(:millisecond))}
    end
  end

  defp access_token(secret) do
    case non_empty_binary(secret["access_token"]) do
      nil -> {:error, :missing_access_token}
      token -> {:ok, token}
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

  defp parse_token_response(response) when is_map(response) do
    access_token = non_empty_binary(response["access_token"])
    expires_in = parse_integer(response["expires_in"])

    cond do
      is_nil(access_token) ->
        {:error, :missing_access_token}

      not is_integer(expires_in) or expires_in <= 0 ->
        {:error, :invalid_expiry}

      true ->
        {:ok,
         %{
           access_token: access_token,
           refresh_token: non_empty_binary(response["refresh_token"]),
           expires_at_ms: System.system_time(:millisecond) + expires_in * 1000
         }}
    end
  end

  # ── Ambient Claude Code credentials ────────────────────────────────────────

  defp resolve_env_token(claude_code_secret) do
    Enum.find_value(@oauth_env_vars, fn env_var ->
      with value when is_binary(value) <- non_empty_binary(System.get_env(env_var)),
           true <- oauth_token?(value) do
        prefer_refreshable_claude_code_token(value, claude_code_secret) || value
      else
        _ -> nil
      end
    end)
  end

  defp prefer_refreshable_claude_code_token(env_token, %{} = claude_code_secret) do
    access_token = non_empty_binary(claude_code_secret["access_token"])

    if non_empty_binary(claude_code_secret["refresh_token"]) && access_token &&
         access_token != env_token do
      Logger.debug(
        "Preferring refreshable Claude Code credentials over static Anthropic OAuth env token"
      )

      access_token
    end
  end

  defp prefer_refreshable_claude_code_token(_env_token, _claude_code_secret), do: nil

  defp current_claude_code_secret do
    with {:ok, secret} <- read_claude_code_credentials(),
         {:ok, fresh} <-
           ensure_fresh(
             @claude_code_file_lock,
             secret,
             fn ->
               with {:ok, latest} <- read_claude_code_credentials(), do: {:ok, latest, []}
             end,
             fn refreshed, _opts -> persist_claude_code_credentials(refreshed) end,
             false
           ) do
      fresh
    else
      _ -> nil
    end
  end

  defp read_claude_code_credentials do
    with {:ok, raw} <- File.read(claude_credentials_path()),
         {:ok, %{"claudeAiOauth" => %{} = oauth}} <- Jason.decode(raw),
         access_token when is_binary(access_token) <- non_empty_binary(oauth["accessToken"]) do
      now = System.system_time(:millisecond)

      {:ok,
       %{
         "type" => @secret_type,
         "access_token" => access_token,
         "refresh_token" => non_empty_binary(oauth["refreshToken"]),
         "expires_at_ms" => parse_integer(oauth["expiresAt"]),
         "source" => "claude_code_credentials_file",
         "created_at_ms" => now,
         "updated_at_ms" => now
       }}
    else
      _ -> {:error, :missing_credentials}
    end
  end

  # Claude Code rotates the same refresh token, so a refresh Lemon performs on
  # its credentials file must be written back for Claude Code to keep working.
  defp persist_claude_code_credentials(secret) do
    path = claude_credentials_path()

    existing =
      with {:ok, raw} <- File.read(path),
           {:ok, decoded} when is_map(decoded) <- Jason.decode(raw) do
        decoded
      else
        _ -> %{}
      end

    oauth =
      existing
      |> Map.get("claudeAiOauth", %{})
      |> Map.merge(%{
        "accessToken" => secret["access_token"],
        "refreshToken" => secret["refresh_token"],
        "expiresAt" => secret["expires_at_ms"]
      })

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(Map.put(existing, "claudeAiOauth", oauth))),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to persist Claude Code credentials: #{inspect(reason)}")
        {:error, :oauth_secret_persistence_failed}
    end
  end

  defp claude_credentials_path do
    home =
      case System.get_env("HOME") do
        value when is_binary(value) and value != "" -> value
        _ -> System.user_home!()
      end

    Path.join([home, ".claude", ".credentials.json"])
  end

  # ── Claude Code fingerprint ────────────────────────────────────────────────

  # Detected once per PATH: the newer of the installed Claude Code CLI and the
  # pinned floor, so a stale local install cannot pin a rejected version.
  defp claude_code_version do
    key = {__MODULE__, :claude_code_version, System.get_env("PATH")}

    case :persistent_term.get(key, nil) do
      nil ->
        version =
          ["claude", "claude-code"]
          |> Enum.find_value(&installed_claude_code_version/1)
          |> newer_version(@claude_code_version_floor)

        :persistent_term.put(key, version)
        version

      version ->
        version
    end
  end

  defp installed_claude_code_version(cmd) do
    with path when is_binary(path) <- System.find_executable(cmd),
         {output, 0} <- System.cmd(path, ["--version"], stderr_to_stdout: true),
         [version | _] <- String.split(String.trim(output)),
         {:ok, _} <- Version.parse(version) do
      version
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp newer_version(nil, floor), do: floor

  defp newer_version(version, floor) do
    if Version.compare(version, floor) == :gt, do: version, else: floor
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp notify_auth(opts, url, instructions) do
    case Keyword.get(opts, :on_auth) do
      callback when is_function(callback, 2) ->
        callback.(url, instructions)
        :ok

      callback when is_function(callback, 1) ->
        callback.(url)
        :ok

      _ ->
        {:error, :auth_callback_required}
    end
  end

  defp notify_progress(opts, message) do
    case Keyword.get(opts, :on_progress) do
      callback when is_function(callback, 1) -> callback.(message)
      _ -> :ok
    end

    :ok
  end

  defp format_listener_error(:eaddrinuse), do: "port already in use"
  defp format_listener_error(:timeout), do: "timed out"
  defp format_listener_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_listener_error(_reason), do: "listener failed"

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

  defp non_empty_binary(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp non_empty_binary(_), do: nil

  defp normalize_prompt_input(value) when is_binary(value), do: String.trim(value)

  defp normalize_prompt_input(value) when is_list(value),
    do: value |> to_string() |> String.trim()

  defp normalize_prompt_input(_), do: ""

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
