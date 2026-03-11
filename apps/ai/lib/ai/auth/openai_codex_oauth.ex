defmodule Ai.Auth.OpenAICodexOAuth do
  @moduledoc """
  OpenAI Codex OAuth helpers.

  Supports PKCE authorization URL generation, manual code parsing,
  code/token exchange, refresh, and encrypted secret resolution.
  """

  require Logger

  alias Ai.Auth.OAuthPKCE
  alias LemonCore.Secrets
  alias LemonCore.Onboarding.LocalCallbackListener

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @authorize_url "https://auth.openai.com/oauth/authorize"
  @token_url "https://auth.openai.com/oauth/token"
  @default_redirect_uri "http://localhost:1455/auth/callback"
  @scope "openid profile email offline_access"
  @jwt_claim_path "https://api.openai.com/auth"
  @secret_type "openai_codex_oauth"
  @near_expiry_ms 10 * 60 * 1000
  @default_secret_names ["llm_openai_codex_api_key"]
  @default_callback_timeout_ms 120_000

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
  Lemon listens for the browser callback automatically and falls back to manual
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
               exchange_code_for_secret(code, auth.code_verifier, redirect_uri: auth.redirect_uri) do
          {:ok, secret}
        end
      after
        stop_local_callback_listener(listener)
      end
    end
  end

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

    with {:ok, data} <- post_form(@token_url, body),
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
  Encode OAuth secret payload for encrypted `LemonCore.Secrets` storage.
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
        if decoded["type"] == @secret_type do
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

  def resolve_api_key_from_secret(_, _), do: {:error, :invalid_secret_value}

  @doc """
  Resolve a Codex access token using env-first resolution and Lemon secret-store OAuth.

  Resolution order:
  1. `OPENAI_CODEX_API_KEY` (env first, then same-name Lemon secret)
  2. `CHATGPT_TOKEN` (env first, then same-name Lemon secret)
  3. Default Lemon OAuth secret names (for example `llm_openai_codex_api_key`)
  """
  @spec resolve_access_token() :: String.t() | nil
  def resolve_access_token do
    resolve_named_secret("OPENAI_CODEX_API_KEY", prefer_env: true, env_fallback: true) ||
      resolve_named_secret("CHATGPT_TOKEN", prefer_env: true, env_fallback: true) ||
      Enum.find_value(@default_secret_names, fn secret_name ->
        resolve_named_secret(secret_name, prefer_env: false, env_fallback: false)
      end)
  end

  defp resolve_named_secret(secret_name, opts) when is_binary(secret_name) do
    with {:ok, value, _source} <- Secrets.resolve(secret_name, opts) do
      case resolve_api_key_from_secret(secret_name, value) do
        {:ok, api_key} ->
          api_key

        :ignore ->
          non_empty_binary(value)

        {:error, reason} ->
          Logger.debug(
            "Failed to resolve OpenAI Codex OAuth secret #{secret_name}: #{inspect(reason)}"
          )

          non_empty_binary(value)
      end
    else
      _ -> nil
    end
  end

  defp ensure_fresh_secret(secret) when is_map(secret) do
    access_token = non_empty_binary(secret["access_token"])
    refresh_token = non_empty_binary(secret["refresh_token"])
    expires_at_ms = parse_integer(secret["expires_at_ms"])

    should_refresh? =
      cond do
        is_nil(refresh_token) -> false
        is_nil(access_token) -> true
        is_nil(expires_at_ms) -> false
        true -> near_expiry?(expires_at_ms)
      end

    if should_refresh? do
      case refresh_access_token(refresh_token, refresh_token) do
        {:ok, refreshed} ->
          account_id = extract_account_id(refreshed.access_token)

          updated =
            secret
            |> Map.put("access_token", refreshed.access_token)
            |> Map.put("refresh_token", refreshed.refresh_token)
            |> Map.put("expires_at_ms", refreshed.expires_at_ms)
            |> maybe_put("account_id", account_id)
            |> Map.put("updated_at_ms", System.system_time(:millisecond))

          {:ok, updated, true}

        {:error, reason} ->
          if is_binary(access_token) and access_token != "" do
            Logger.debug(
              "OpenAI Codex OAuth refresh failed; using existing token: #{inspect(reason)}"
            )

            {:ok, secret, false}
          else
            {:error, reason}
          end
      end
    else
      {:ok, secret, false}
    end
  end

  defp refresh_access_token(refresh_token, fallback_refresh_token)
       when is_binary(refresh_token) and refresh_token != "" do
    body = %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "client_id" => oauth_client_id()
    }

    with {:ok, data} <- post_form(@token_url, body),
         {:ok, token_data} <- parse_token_response(data) do
      {:ok,
       %{
         access_token: token_data.access_token,
         refresh_token: token_data.refresh_token || fallback_refresh_token,
         expires_at_ms: token_data.expires_at_ms
       }}
    end
  end

  defp refresh_access_token(_, _), do: {:error, :missing_refresh_token}

  defp parse_token_response(data) when is_map(data) do
    access_token = non_empty_binary(data["access_token"])
    refresh_token = non_empty_binary(data["refresh_token"])
    expires_in = parse_integer(data["expires_in"])

    cond do
      is_nil(access_token) ->
        {:error, {:invalid_token_response, data}}

      is_nil(expires_in) or expires_in <= 0 ->
        {:error, {:invalid_expiry, data}}

      true ->
        {:ok,
         %{
           access_token: access_token,
           refresh_token: refresh_token,
           expires_at_ms: System.system_time(:millisecond) + expires_in * 1000 - @near_expiry_ms
         }}
    end
  end

  defp parse_token_response(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, decoded} when is_map(decoded) -> parse_token_response(decoded)
      _ -> {:error, {:invalid_token_response, data}}
    end
  end

  defp parse_token_response(other), do: {:error, {:invalid_token_response, other}}

  defp persist_secret(secret_name, secret) do
    case Secrets.set(secret_name, encode_secret(secret), provider: "openai_codex_oauth") do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.debug(
          "Failed to persist refreshed OpenAI Codex OAuth secret #{secret_name}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp post_form(url, body) when is_map(body) do
    headers = %{"content-type" => "application/x-www-form-urlencoded"}

    case Req.post(url, headers: headers, body: URI.encode_query(body)) do
      {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:http_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_account_id(token) when is_binary(token) do
    with [_header, payload, _signature] <- String.split(token, ".", parts: 3),
         {:ok, decoded} <- decode_base64url(payload),
         {:ok, claims} <- Jason.decode(decoded),
         account_id when is_binary(account_id) and account_id != "" <-
           get_in(claims, [@jwt_claim_path, "chatgpt_account_id"]) do
      account_id
    else
      _ -> nil
    end
  end

  defp extract_account_id(_), do: nil

  defp decode_base64url(str) when is_binary(str) do
    str
    |> String.replace("-", "+")
    |> String.replace("_", "/")
    |> pad_base64()
    |> Base.decode64()
  end

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
    if Keyword.get(opts, :listen_for_callback, true) and
         LocalCallbackListener.local_redirect_uri?(redirect_uri) do
      case LocalCallbackListener.start(redirect_uri) do
        {:ok, listener} ->
          listener

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

  defp wait_for_local_callback(opts, redirect_uri, listener) do
    timeout_ms = Keyword.get(opts, :callback_timeout_ms, @default_callback_timeout_ms)

    _ =
      notify_progress(
        opts,
        "Waiting for browser callback on #{redirect_uri} ..."
      )

    case LocalCallbackListener.wait(listener, timeout_ms) do
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
  defp stop_local_callback_listener(listener), do: LocalCallbackListener.stop(listener)

  defp auth_instructions(_redirect_uri, nil) do
    "Paste the callback URL (or code#state) after browser sign-in."
  end

  defp auth_instructions(redirect_uri, _listener) do
    "After browser sign-in, Lemon will capture the redirect to #{redirect_uri} automatically."
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
