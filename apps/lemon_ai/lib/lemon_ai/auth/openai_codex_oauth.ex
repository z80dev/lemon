defmodule LemonAi.Auth.OpenAICodexOAuth do
  @moduledoc """
  OpenAI Codex OAuth helpers.

  Supports PKCE authorization URL generation, automatic localhost callback capture
  with manual code fallback, headless device-code sign-in (`login_device_code/1`),
  code/token exchange, refresh, and encrypted secret resolution.
  `import_codex_cli_login/1` explicitly copies a ChatGPT OAuth login from the selected
  Codex CLI auth file into a canonical secret payload. Import never contacts the
  network or modifies the source file; callers own encrypted storage and refresh
  persistence through `:persist_secret`.
  """

  require Logger

  alias LemonAi.Auth.OAuthPKCE

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @authorize_url "https://auth.openai.com/oauth/authorize"
  @token_url "https://auth.openai.com/oauth/token"
  @default_redirect_uri "http://localhost:1455/auth/callback"
  @scope "openid profile email offline_access"
  @jwt_claim_path "https://api.openai.com/auth"
  @secret_type "openai_codex_oauth"
  @legacy_secret_types ["onboarding_openai_codex_oauth"]
  @near_expiry_ms 10 * 60 * 1000
  @default_callback_timeout_ms 120_000
  @device_usercode_url "https://auth.openai.com/api/accounts/deviceauth/usercode"
  @device_token_url "https://auth.openai.com/api/accounts/deviceauth/token"
  @device_verification_url "https://auth.openai.com/codex/device"
  @device_redirect_uri "https://auth.openai.com/deviceauth/callback"
  @device_poll_margin_ms 3_000
  @device_max_polls 120

  @type oauth_secret :: %{required(String.t()) => String.t() | integer() | nil}
  @type login_opt ::
          {:on_auth, (String.t(), String.t() | nil -> any())}
          | {:on_progress, (String.t() -> any())}
          | {:on_prompt, (map() -> String.t() | charlist())}
          | {:originator, String.t()}
          | {:redirect_uri, String.t()}
          | {:state, String.t()}
          | {:callback_timeout_ms, pos_integer()}
          | {:listen_for_callback, boolean()}
          | {:local_callback_listener, module()}
          | {:persist_secret, (String.t(), String.t() -> any())}

  @doc false
  @spec oauth_client_id() :: String.t()
  def oauth_client_id do
    case System.get_env("OPENAI_CODEX_OAUTH_CLIENT_ID") do
      value when is_binary(value) and value != "" -> value
      _ -> @client_id
    end
  end

  @doc """
  Build an OAuth authorization URL + PKCE verifier/state.
  """
  @spec authorize_url(keyword()) :: {:ok, map()}
  def authorize_url(opts \\ []), do: build_authorize_url(opts)

  @doc """
  Run OpenAI Codex OAuth flow.

  When the redirect URI is local (`http://localhost:1455/auth/callback` by default),
  A local listener can capture the browser callback automatically and fall back to manual
  paste only if that listener cannot complete the flow.
  """
  @spec login_device_flow([login_opt()]) :: {:ok, oauth_secret()} | {:error, term()}
  def login_device_flow(opts \\ []) when is_list(opts) do
    with {:ok, auth} <- build_authorize_url(opts) do
      listener = maybe_start_local_callback_listener(auth.redirect_uri, opts)

      try do
        with :ok <-
               notify_auth(
                 opts,
                 auth.authorize_url,
                 auth_instructions(auth.redirect_uri, listener)
               ),
             {:ok, %{code: code, state: state}} <- prompt_code(opts, auth.redirect_uri, listener),
             :ok <- ensure_state_matches(auth.state, state),
             :ok <- notify_progress(opts, "Exchanging authorization code for tokens..."),
             {:ok, secret} <-
               exchange_code_for_secret(
                 code,
                 auth.code_verifier,
                 Keyword.put(opts, :redirect_uri, auth.redirect_uri)
               ) do
          {:ok, secret}
        end
      after
        stop_local_callback_listener(listener)
      end
    end
  end

  @doc """
  Sign in with ChatGPT's device-code flow, without a local callback server.

  Useful on headless machines or when port 1455 is busy. Shows
  `https://auth.openai.com/codex/device` and a user code through `:on_auth`,
  polls until the user approves, then exchanges the returned authorization
  code exactly like the browser flow, so the payload is the same refreshable
  Codex login. Polls wait the server interval plus three seconds, at most
  #{@device_max_polls} times and never beyond device-code expiry (15 minutes
  when omitted by the server). Optional: `:on_progress`, `:sleep` (milliseconds),
  `:now` (monotonic milliseconds), `:req_options`, and
  `:device_usercode_url`/`:device_token_url`/`:token_url` overrides for local fakes.
  """
  @spec login_device_code(keyword()) :: {:ok, oauth_secret()} | {:error, term()}
  def login_device_code(opts \\ []) when is_list(opts) do
    notify_progress(opts, "Requesting ChatGPT device authorization...")

    with {:ok, device} <- start_device_authorization(opts),
         :ok <-
           LemonAi.Auth.OAuthFlow.notify_auth(
             opts,
             Keyword.get(opts, :device_verification_url, @device_verification_url),
             "Enter code: #{device.user_code}"
           ),
         :ok <- notify_progress(opts, "Waiting for device authorization..."),
         {:ok, %{code: code, verifier: verifier}} <- poll_device_authorization(device, opts),
         :ok <- notify_progress(opts, "Exchanging authorization code for tokens...") do
      exchange_code_for_secret(
        code,
        verifier,
        Keyword.put(opts, :redirect_uri, @device_redirect_uri)
      )
    end
  end

  defp start_device_authorization(opts) do
    url = Keyword.get(opts, :device_usercode_url, @device_usercode_url)

    case LemonAi.Auth.OAuthFlow.request(url, [json: %{"client_id" => oauth_client_id()}], opts) do
      {:ok, %{status: status, body: %{} = body}} when status in 200..299 ->
        device_auth_id = non_empty_binary(body["device_auth_id"])
        user_code = non_empty_binary(body["user_code"])
        expires_in = parse_integer(body["expires_in"])
        lifetime_ms = (expires_in || 900) * 1000
        now = Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end)

        if device_auth_id && user_code &&
             (is_nil(body["expires_in"]) or (is_integer(expires_in) and expires_in > 0)) do
          interval_s = parse_integer(body["interval"]) || 5

          {:ok,
           %{
             device_auth_id: device_auth_id,
             user_code: user_code,
             interval_ms: max(interval_s, 1) * 1000 + @device_poll_margin_ms,
             lifetime_ms: lifetime_ms,
             deadline_ms: now.() + lifetime_ms
           }}
        else
          {:error, :invalid_device_authorization_response}
        end

      {:ok, %{status: status}} ->
        {:error, {:device_authorization_failed, status}}

      {:error, _} = error ->
        error
    end
  end

  defp poll_device_authorization(device, opts) do
    now = Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end)
    do_poll_device(device, opts, now, 1, device.lifetime_ms)
  end

  defp do_poll_device(_device, _opts, _now, poll, _remaining_ms)
       when poll > @device_max_polls,
       do: {:error, :device_flow_timed_out}

  defp do_poll_device(device, opts, now, poll, remaining_ms) do
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    wait_ms = if poll == 1, do: min(device.interval_ms, 5_000), else: device.interval_ms
    remaining_ms = min(remaining_ms, device.deadline_ms - now.())

    if remaining_ms <= wait_ms do
      {:error, :device_flow_timed_out}
    else
      sleep.(wait_ms)
      started_at = now.()
      remaining_ms = min(remaining_ms - wait_ms, device.deadline_ms - started_at)

      if remaining_ms <= 0 do
        {:error, :device_flow_timed_out}
      else
        url = Keyword.get(opts, :device_token_url, @device_token_url)
        body = %{"device_auth_id" => device.device_auth_id, "user_code" => device.user_code}
        result = LemonAi.Auth.OAuthFlow.request(url, [json: body], opts)

        remaining_ms =
          min(remaining_ms - max(now.() - started_at, 0), device.deadline_ms - now.())

        case result do
          {:ok, _} when remaining_ms <= 0 ->
            {:error, :device_flow_timed_out}

          # The endpoint answers 403/404 until the user approves.
          {:ok, %{status: status}} when status in [403, 404] ->
            do_poll_device(device, opts, now, poll + 1, remaining_ms)

          {:ok, %{status: status, body: %{} = response}} when status in 200..299 ->
            code = non_empty_binary(response["authorization_code"])
            verifier = non_empty_binary(response["code_verifier"])

            if code && verifier,
              do: {:ok, %{code: code, verifier: verifier}},
              else: {:error, :invalid_device_token_response}

          {:ok, %{status: status}} ->
            {:error, {:device_token_failed, status}}

          {:error, _} = error ->
            error
        end
      end
    end
  end

  @doc """
  Import an existing Codex CLI ChatGPT login without refreshing or writing it.

  Reads only `:path`, or `CODEX_HOME/auth.json`, or `HOME/.codex/auth.json`
  (in that order). Returns the canonical refreshable OAuth secret, not an encoded
  string. Expired access tokens are accepted when refreshable; resolution refreshes
  them later. API-key logins and incomplete OAuth data return credential-free errors.
  """
  @spec import_codex_cli_login(keyword()) :: {:ok, oauth_secret()} | {:error, atom() | tuple()}
  def import_codex_cli_login(opts \\ []) do
    with {:ok, path} <- codex_auth_path(opts),
         {:ok, contents} <- File.read(path),
         {:ok, login} <- decode_codex_login(contents),
         {:ok, secret} <- import_codex_tokens(login) do
      {:ok, secret}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_codex_cli_login}
    end
  end

  defp codex_auth_path(opts) do
    case Keyword.get(opts, :path) do
      nil ->
        home = non_empty_binary(System.get_env("HOME"))
        codex_home = non_empty_binary(System.get_env("CODEX_HOME"))

        cond do
          codex_home -> {:ok, Path.join(codex_home, "auth.json")}
          home -> {:ok, Path.join([home, ".codex", "auth.json"])}
          true -> {:error, :missing_home}
        end

      path when is_binary(path) and path != "" ->
        {:ok, path}

      _ ->
        {:error, :invalid_codex_auth_path}
    end
  end

  defp decode_codex_login(contents) do
    case Jason.decode(contents) do
      {:ok, login} when is_map(login) -> {:ok, login}
      _ -> {:error, :invalid_codex_cli_login}
    end
  end

  defp import_codex_tokens(%{"tokens" => tokens} = login) when is_map(tokens) do
    access_token = non_empty_binary(tokens["access_token"])
    refresh_token = non_empty_binary(tokens["refresh_token"])
    id_token = non_empty_binary(tokens["id_token"])
    claims = token_claims(access_token)
    expires_at = claims && claims["exp"]

    account_id =
      non_empty_binary(tokens["account_id"]) ||
        extract_account_id(access_token) || extract_account_id(id_token)

    cond do
      login["auth_mode"] not in [nil, "chatgpt"] ->
        {:error, :not_chatgpt_oauth}

      is_nil(access_token) or is_nil(claims) ->
        {:error, :invalid_access_token}

      is_nil(refresh_token) ->
        {:error, :missing_refresh_token}

      not is_integer(expires_at) or expires_at <= 0 ->
        {:error, :invalid_expiry}

      is_nil(account_id) ->
        {:error, :missing_account_id}

      true ->
        now = System.system_time(:millisecond)

        {:ok,
         %{
           "type" => @secret_type,
           "access_token" => access_token,
           "refresh_token" => refresh_token,
           "expires_at_ms" => expires_at * 1000,
           "account_id" => account_id,
           "created_at_ms" => now,
           "updated_at_ms" => now
         }
         |> maybe_put("id_token", id_token)}
    end
  end

  defp import_codex_tokens(_), do: {:error, :not_chatgpt_oauth}

  @doc """
  Build an OAuth authorization URL + PKCE verifier/state.
  """
  @spec build_authorize_url(keyword()) :: {:ok, map()}
  def build_authorize_url(opts \\ []) do
    redirect_uri = Keyword.get(opts, :redirect_uri, @default_redirect_uri)
    originator = Keyword.get(opts, :originator, "lemon")
    %{verifier: verifier, challenge: challenge} = OAuthPKCE.generate()
    state = Keyword.get(opts, :state, OAuthPKCE.random_state())

    params =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => oauth_client_id(),
        "redirect_uri" => redirect_uri,
        "scope" => @scope,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => state,
        "id_token_add_organizations" => "true",
        "codex_cli_simplified_flow" => "true",
        "originator" => originator
      })

    {:ok,
     %{
       authorize_url: "#{@authorize_url}?#{params}",
       code_verifier: verifier,
       state: state,
       redirect_uri: redirect_uri,
       created_at_ms: System.system_time(:millisecond)
     }}
  end

  @doc """
  Parse manual pasted OAuth input. Accepts:
  - full callback URL
  - query string containing `code=`
  - `code#state`
  - plain code
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
          parse_authorization_url(value)

        String.contains?(value, "#") ->
          case String.split(value, "#", parts: 2) do
            [code, state] -> %{code: non_empty_binary(code), state: non_empty_binary(state)}
            _ -> %{code: nil, state: nil}
          end

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
  Exchange authorization code + PKCE verifier for an OAuth secret payload.
  """
  @spec exchange_code_for_secret(String.t(), String.t(), keyword()) ::
          {:ok, oauth_secret()} | {:error, term()}
  def exchange_code_for_secret(code, code_verifier, opts \\ [])

  def exchange_code_for_secret(code, code_verifier, opts)
      when is_binary(code) and is_binary(code_verifier) do
    redirect_uri = Keyword.get(opts, :redirect_uri, @default_redirect_uri)

    body = %{
      "grant_type" => "authorization_code",
      "client_id" => oauth_client_id(),
      "code" => code,
      "code_verifier" => code_verifier,
      "redirect_uri" => redirect_uri
    }

    with {:ok, data} <- post_form(Keyword.get(opts, :token_url, @token_url), body, opts),
         {:ok, token_data} <- parse_token_response(data),
         account_id when is_binary(account_id) and account_id != "" <-
           extract_account_id(token_data.access_token) do
      now = System.system_time(:millisecond)

      {:ok,
       %{
         "type" => @secret_type,
         "access_token" => token_data.access_token,
         "refresh_token" => token_data.refresh_token,
         "expires_at_ms" => token_data.expires_at_ms,
         "account_id" => account_id,
         "redirect_uri" => redirect_uri,
         "created_at_ms" => now,
         "updated_at_ms" => now
       }}
    else
      nil -> {:error, :missing_account_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def exchange_code_for_secret(_, _, _), do: {:error, :invalid_authorization_input}

  @doc """
  Encode OAuth secret payload for storage by the caller.
  """
  @spec encode_secret(oauth_secret()) :: String.t()
  def encode_secret(secret) when is_map(secret), do: Jason.encode!(secret)

  @doc """
  Decode OAuth secret payload.
  """
  @spec decode_secret(String.t()) :: {:ok, oauth_secret()} | :not_oauth
  def decode_secret(secret_value) when is_binary(secret_value) do
    case Jason.decode(secret_value) do
      {:ok, decoded} when is_map(decoded) ->
        if oauth_secret_type?(decoded["type"]) do
          {:ok, decoded}
        else
          :not_oauth
        end

      _ ->
        :not_oauth
    end
  end

  def decode_secret(_), do: :not_oauth

  @doc """
  Resolve a usable Codex access token from an OAuth secret.

  Returns `:ignore` for non-Codex-OAuth payloads.

  Codex refresh tokens rotate, so a refresh runs under a per-secret lock and
  re-reads the stored secret through `:reload_secret` first: a caller queued
  behind a refresh uses the rotated token instead of replaying the consumed
  refresh token. `force_refresh: true` refreshes even an unexpired token (the
  provider rejected it) unless the stored token already differs from the
  rejected one, and never falls back to the rejected token.
  """
  @spec resolve_api_key_from_secret(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  def resolve_api_key_from_secret(secret_name, secret_value, opts \\ [])

  def resolve_api_key_from_secret(secret_name, secret_value, opts)
      when is_binary(secret_name) and is_binary(secret_value) do
    force? = Keyword.get(opts, :force_refresh, false) == true

    with {:ok, secret} <- decode_secret(secret_value),
         {:ok, fresh_secret} <- ensure_fresh(secret_name, secret, force?, opts),
         access_token when is_binary(access_token) and access_token != "" <-
           non_empty_binary(fresh_secret["access_token"]) do
      {:ok, access_token}
    else
      :not_oauth -> :ignore
      nil -> {:error, :missing_access_token}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_api_key_from_secret(_, _, _), do: {:error, :invalid_secret_value}

  @doc """
  Resolve a Codex access token from process environment values.

  Resolution order:
  1. `OPENAI_CODEX_API_KEY`
  2. `CHATGPT_TOKEN`
  """
  @spec resolve_access_token() :: String.t() | nil
  def resolve_access_token do
    non_empty_binary(System.get_env("OPENAI_CODEX_API_KEY")) ||
      non_empty_binary(System.get_env("CHATGPT_TOKEN"))
  end

  defp ensure_fresh(secret_name, secret, force?, opts) do
    if force? or refresh_due?(secret) do
      :global.trans(
        {{__MODULE__, :refresh, secret_name}, self()},
        fn ->
          with {:ok, latest} <- reload_latest_secret(secret_name, secret, opts) do
            cond do
              force? and latest["access_token"] == secret["access_token"] ->
                refresh_and_persist(secret_name, latest, true, opts)

              not force? and refresh_due?(latest) ->
                refresh_and_persist(secret_name, latest, false, opts)

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

  defp refresh_due?(secret) do
    access_token = non_empty_binary(secret["access_token"])
    expires_at_ms = token_expiry_ms(access_token, parse_integer(secret["expires_at_ms"]))

    cond do
      is_nil(non_empty_binary(secret["refresh_token"])) -> false
      is_nil(access_token) -> true
      is_nil(expires_at_ms) -> false
      true -> near_expiry?(expires_at_ms)
    end
  end

  defp usable(secret) do
    access_token = non_empty_binary(secret["access_token"])
    expires_at_ms = token_expiry_ms(access_token, parse_integer(secret["expires_at_ms"]))

    if is_integer(expires_at_ms) and expires_at_ms <= System.system_time(:millisecond) do
      {:error, :expired_access_token}
    else
      {:ok, secret}
    end
  end

  # Without a reload callback the caller's copy is the latest one available.
  defp reload_latest_secret(secret_name, stale, opts) do
    case Keyword.get(opts, :reload_secret) do
      reload when is_function(reload, 1) ->
        with {:ok, value} when is_binary(value) <- reload.(secret_name),
             {:ok, latest} <- decode_secret(value) do
          {:ok, latest}
        else
          :not_oauth -> {:error, :oauth_secret_replaced}
          _ -> {:error, :oauth_secret_missing}
        end

      _ ->
        {:ok, stale}
    end
  end

  defp refresh_and_persist(secret_name, secret, force?, opts) do
    access_token = non_empty_binary(secret["access_token"])
    expires_at_ms = token_expiry_ms(access_token, parse_integer(secret["expires_at_ms"]))

    case non_empty_binary(secret["refresh_token"]) do
      nil ->
        {:error, :not_refreshable}

      refresh_token ->
        case refresh_access_token(refresh_token, refresh_token, opts) do
          {:ok, refreshed} ->
            account_id = extract_account_id(refreshed.access_token)

            updated =
              secret
              |> Map.put("access_token", refreshed.access_token)
              |> Map.put("refresh_token", refreshed.refresh_token)
              |> Map.put("expires_at_ms", refreshed.expires_at_ms)
              |> maybe_put("account_id", account_id)
              |> Map.put("updated_at_ms", System.system_time(:millisecond))

            with :ok <- persist_secret(secret_name, updated, opts), do: {:ok, updated}

          {:error, :reauth_required} = error ->
            error

          {:error, reason} ->
            if not force? and is_binary(access_token) and is_integer(expires_at_ms) and
                 expires_at_ms > System.system_time(:millisecond) do
              Logger.debug("OpenAI Codex OAuth refresh failed; using unexpired existing token")

              {:ok, secret}
            else
              {:error, reason}
            end
        end
    end
  end

  defp refresh_access_token(refresh_token, fallback_refresh_token, opts)
       when is_binary(refresh_token) and refresh_token != "" do
    body = %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "client_id" => oauth_client_id()
    }

    with {:ok, data} <- post_form(Keyword.get(opts, :token_url, @token_url), body, opts),
         {:ok, token_data} <- parse_token_response(data) do
      {:ok,
       %{
         access_token: token_data.access_token,
         refresh_token: token_data.refresh_token || fallback_refresh_token,
         expires_at_ms: token_data.expires_at_ms
       }}
    end
  end

  defp refresh_access_token(_, _, _), do: {:error, :missing_refresh_token}

  defp parse_token_response(data) when is_map(data) do
    access_token = non_empty_binary(data["access_token"])
    refresh_token = non_empty_binary(data["refresh_token"])
    expires_in = parse_integer(data["expires_in"])

    cond do
      is_nil(access_token) ->
        {:error, :invalid_token_response}

      is_nil(expires_in) or expires_in <= 0 ->
        {:error, :invalid_expiry}

      true ->
        {:ok,
         %{
           access_token: access_token,
           refresh_token: refresh_token,
           expires_at_ms: System.system_time(:millisecond) + expires_in * 1000
         }}
    end
  end

  defp parse_token_response(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, decoded} when is_map(decoded) -> parse_token_response(decoded)
      _ -> {:error, :invalid_token_response}
    end
  end

  defp parse_token_response(_), do: {:error, :invalid_token_response}

  defp persist_secret(secret_name, secret, opts) do
    encoded = encode_secret(secret)

    case Keyword.get(opts, :persist_secret) do
      callback when is_function(callback, 2) ->
        case callback.(secret_name, encoded) do
          {:error, _} -> {:error, :oauth_secret_persistence_failed}
          _ -> :ok
        end

      _ ->
        :ok
    end
  rescue
    _ ->
      {:error, :oauth_secret_persistence_failed}
  end

  defp post_form(url, body, opts) when is_map(body) do
    case LemonAi.Auth.OAuthFlow.request(url, [form: body], opts) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %{status: status, body: %{"error" => "invalid_grant"}}}
      when status in [400, 401] ->
        {:error, :reauth_required}

      {:ok, %{status: status, body: response_body}} ->
        {:error, LemonAi.Auth.OAuthFlow.http_error(status, response_body)}

      {:error, _} = error ->
        error
    end
  end

  defp token_expiry_ms(token, stored_expiry) do
    case token_claims(token) do
      %{"exp" => exp} when is_integer(exp) ->
        if is_integer(stored_expiry), do: min(stored_expiry, exp * 1000), else: exp * 1000

      _ ->
        stored_expiry
    end
  end

  defp extract_account_id(token) do
    case token_claims(token) do
      %{@jwt_claim_path => %{"chatgpt_account_id" => account_id}} ->
        non_empty_binary(account_id)

      _ ->
        nil
    end
  end

  defp token_claims(token) when is_binary(token) do
    with [header, payload, signature] when header != "" and signature != "" <-
           String.split(token, ".", parts: 3),
         {:ok, decoded} <- decode_base64url(payload),
         {:ok, claims} when is_map(claims) <- Jason.decode(decoded) do
      claims
    else
      _ -> nil
    end
  end

  defp token_claims(_), do: nil

  defp decode_base64url(str) when is_binary(str) do
    str
    |> String.replace("-", "+")
    |> String.replace("_", "/")
    |> pad_base64()
    |> Base.decode64()
  end

  defp oauth_secret_type?(type) when type == @secret_type, do: true
  defp oauth_secret_type?(type) when type in @legacy_secret_types, do: true
  defp oauth_secret_type?(_type), do: false

  defp pad_base64(str) do
    case rem(String.length(str), 4) do
      0 -> str
      2 -> str <> "=="
      3 -> str <> "="
      _ -> str
    end
  end

  defp parse_authorization_url(value) do
    case URI.parse(value) do
      %URI{query: query} when is_binary(query) and query != "" ->
        params = URI.decode_query(query)
        %{code: params["code"], state: params["state"]}

      _ ->
        %{code: nil, state: nil}
    end
  end

  defp near_expiry?(expires_at_ms) when is_integer(expires_at_ms) do
    System.system_time(:millisecond) + @near_expiry_ms >= expires_at_ms
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_float(value) do
    trunc(value)
  end

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp non_empty_binary(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_empty_binary(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp prompt_code(opts, redirect_uri, listener) do
    case wait_for_local_callback(opts, redirect_uri, listener) do
      {:ok, value} ->
        parse_authorization_input(value)

      :manual ->
        prompt_code_manually(opts)
    end
  end

  defp prompt_code_manually(opts) do
    prompt_callback = Keyword.get(opts, :on_prompt)

    value =
      cond do
        is_function(prompt_callback, 1) ->
          prompt_callback.(%{
            message: "Paste callback URL (or code#state):",
            placeholder: "http://localhost:1455/auth/callback?code=..."
          })

        is_function(prompt_callback, 0) ->
          prompt_callback.()

        true ->
          nil
      end

    if is_nil(value) do
      {:error, :prompt_callback_required}
    else
      value
      |> normalize_prompt_input()
      |> parse_authorization_input()
    end
  end

  defp maybe_start_local_callback_listener(redirect_uri, opts) do
    listener_module = Keyword.get(opts, :local_callback_listener)

    if (Keyword.get(opts, :listen_for_callback, true) and listener_module) &&
         listener_module.local_redirect_uri?(redirect_uri) do
      case listener_module.start(redirect_uri) do
        {:ok, listener} ->
          {listener_module, listener}

        {:error, reason} ->
          _ =
            notify_progress(
              opts,
              "Could not start localhost OAuth callback listener: #{format_local_callback_error(reason)}. Falling back to manual paste."
            )

          nil
      end
    else
      nil
    end
  end

  defp wait_for_local_callback(_opts, _redirect_uri, nil), do: :manual

  defp wait_for_local_callback(opts, redirect_uri, {listener_module, listener}) do
    timeout_ms = Keyword.get(opts, :callback_timeout_ms, @default_callback_timeout_ms)

    _ =
      notify_progress(
        opts,
        "Waiting for browser callback on #{redirect_uri} ..."
      )

    case listener_module.wait(listener, timeout_ms) do
      {:ok, callback_url} ->
        _ = notify_progress(opts, "Received browser callback. Finishing sign-in...")
        {:ok, callback_url}

      {:error, :timeout} ->
        _ =
          notify_progress(
            opts,
            "Did not receive the browser callback automatically. Paste the callback URL or code to continue."
          )

        :manual

      {:error, reason} ->
        _ =
          notify_progress(
            opts,
            "Automatic callback capture failed: #{format_local_callback_error(reason)}. Paste the callback URL or code to continue."
          )

        :manual
    end
  end

  defp stop_local_callback_listener(nil), do: :ok

  defp stop_local_callback_listener({listener_module, listener}),
    do: listener_module.stop(listener)

  defp auth_instructions(_redirect_uri, nil) do
    "Paste the callback URL (or code#state) after browser sign-in."
  end

  defp auth_instructions(redirect_uri, _listener) do
    "After browser sign-in, the local callback listener will capture the redirect to #{redirect_uri} automatically."
  end

  defp format_local_callback_error(:eaddrinuse), do: "port already in use"
  defp format_local_callback_error(:unsupported_redirect_uri), do: "redirect URI is not local"
  defp format_local_callback_error(reason), do: inspect(reason)

  defp notify_auth(opts, url, instructions) do
    auth_callback = Keyword.get(opts, :on_auth)

    cond do
      is_function(auth_callback, 2) ->
        auth_callback.(url, instructions)
        :ok

      is_function(auth_callback, 1) ->
        auth_callback.(url)
        :ok

      true ->
        {:error, :auth_callback_required}
    end
  rescue
    _ -> {:error, :auth_callback_failed}
  end

  defp notify_progress(opts, message) when is_binary(message) do
    progress_callback = Keyword.get(opts, :on_progress)

    cond do
      is_function(progress_callback, 1) ->
        progress_callback.(message)
        :ok

      true ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp ensure_state_matches(expected, nil) when is_binary(expected), do: :ok

  defp ensure_state_matches(expected, provided)
       when is_binary(expected) and is_binary(provided) do
    if expected == provided, do: :ok, else: {:error, :oauth_state_mismatch}
  end

  defp ensure_state_matches(_, _), do: :ok

  defp normalize_prompt_input(value) when is_binary(value), do: String.trim(value)

  defp normalize_prompt_input(value) when is_list(value),
    do: value |> List.to_string() |> String.trim()

  defp normalize_prompt_input(_), do: ""
end
