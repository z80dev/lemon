defmodule Ai.Auth.GoogleAntigravityOAuth do
  @moduledoc """
  Google Antigravity OAuth helpers.

  Supports PKCE authorization URL generation, localhost callback/manual paste parsing,
  token exchange + refresh, encrypted secret payloads, and API-key resolution.
  """

  require Logger

  alias Ai.Auth.OAuthPKCE
  alias LemonCore.Secrets

  @authorize_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @default_redirect_uri "http://localhost:51121/oauth-callback"
  @default_project_id "rising-fact-p41fc"
  @client_id_secret_names [
    "google_antigravity_oauth_client_id",
    "GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_ID"
  ]
  @client_secret_secret_names [
    "google_antigravity_oauth_client_secret",
    "GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_SECRET"
  ]
  @scopes [
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/userinfo.profile",
    "https://www.googleapis.com/auth/cclog",
    "https://www.googleapis.com/auth/experimentsandconfigs"
  ]
  @secret_type "google_antigravity_oauth"
  @near_expiry_ms 5 * 60 * 1000

  @type oauth_secret :: %{required(String.t()) => String.t() | integer() | nil}
  @type login_opt ::
          {:on_auth, (String.t(), String.t() | nil -> any())}
          | {:on_progress, (String.t() -> any())}
          | {:on_prompt, (map() -> String.t() | charlist())}
          | {:redirect_uri, String.t()}
          | {:state, String.t()}
          | {:project_id, String.t()}
          | {:email, String.t()}

  @doc false
  @spec oauth_client_id() :: String.t()
  def oauth_client_id do
    resolve_client_credential!(
      @client_id_secret_names,
      "GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_ID",
      "client id"
    )
  end

  @doc false
  @spec oauth_client_secret() :: String.t()
  def oauth_client_secret do
    resolve_client_credential!(
      @client_secret_secret_names,
      "GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_SECRET",
      "client secret"
    )
  end

  @doc """
  Build an OAuth authorization URL + PKCE verifier.

  Defaults to a localhost callback URI (`http://localhost:51121/oauth-callback`).
  """
  @spec authorize_url(keyword()) :: {:ok, map()}
  def authorize_url(opts \\ []), do: build_authorize_url(opts)

  @doc """
  Run Google Antigravity OAuth flow (open URL + paste code/callback URL).
  """
  @spec login_device_flow([login_opt()]) :: {:ok, oauth_secret()} | {:error, term()}
  def login_device_flow(opts \\ []) when is_list(opts) do
    with {:ok, auth} <- build_authorize_url(opts),
         :ok <-
           notify_auth(
             opts,
             auth.authorize_url,
             "Paste the callback URL (or authorization code) after browser sign-in."
           ),
         {:ok, %{code: code, state: state}} <- prompt_code(opts),
         :ok <- ensure_state_matches(auth.state, state),
         :ok <- notify_progress(opts, "Exchanging authorization code for tokens..."),
         {:ok, secret} <-
           exchange_code_for_secret(code, auth.code_verifier,
             redirect_uri: auth.redirect_uri,
             project_id: Keyword.get(opts, :project_id, @default_project_id),
             email: Keyword.get(opts, :email)
           ) do
      {:ok, secret}
    end
  end

  @doc """
  Build an OAuth authorization URL + PKCE verifier.

  Defaults to a localhost callback URI (`http://localhost:51121/oauth-callback`).
  """
  @spec build_authorize_url(keyword()) :: {:ok, map()}
  def build_authorize_url(opts \\ []) do
    redirect_uri = Keyword.get(opts, :redirect_uri, @default_redirect_uri)
    %{verifier: verifier, challenge: challenge} = OAuthPKCE.generate()
    state = Keyword.get(opts, :state, verifier)

    params =
      URI.encode_query(%{
        "client_id" => oauth_client_id(),
        "response_type" => "code",
        "redirect_uri" => redirect_uri,
        "scope" => Enum.join(@scopes, " "),
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => state,
        "access_type" => "offline",
        "prompt" => "consent"
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
  Parse callback/manual pasted OAuth input. Accepts:
  - full callback URL
  - query string containing `code=`
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

  `project_id` may be passed in options; defaults to a fallback project.
  """
  @spec exchange_code_for_secret(String.t(), String.t(), keyword()) ::
          {:ok, oauth_secret()} | {:error, term()}
  def exchange_code_for_secret(code, code_verifier, opts \\ [])

  def exchange_code_for_secret(code, code_verifier, opts)
      when is_binary(code) and is_binary(code_verifier) do
    project_id = Keyword.get(opts, :project_id, @default_project_id)
    redirect_uri = Keyword.get(opts, :redirect_uri, @default_redirect_uri)

    body = %{
      "client_id" => oauth_client_id(),
      "client_secret" => oauth_client_secret(),
      "code" => code,
      "grant_type" => "authorization_code",
      "redirect_uri" => redirect_uri,
      "code_verifier" => code_verifier
    }

    with {:ok, data} <- post_form(@token_url, body),
         {:ok, token_data} <- parse_token_response(data),
         {:ok, secret} <-
           build_oauth_secret(token_data, project_id, Keyword.get(opts, :email), redirect_uri) do
      {:ok, secret}
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

      {:ok, _decoded} ->
        :not_oauth

      {:error, _reason} ->
        :not_oauth
    end
  end

  def decode_secret(_), do: :not_oauth

  @doc """
  Resolve a usable Google Antigravity API key JSON string (`{"token","projectId"}`)
  from a secret value.

  Returns `:ignore` for non-Antigravity-OAuth payloads.
  """
  @spec resolve_api_key_from_secret(String.t(), String.t()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  def resolve_api_key_from_secret(secret_name, secret_value)
      when is_binary(secret_name) and is_binary(secret_value) do
    with {:ok, secret} <- decode_secret(secret_value),
         {:ok, refreshed_secret, changed?} <- ensure_fresh_secret(secret),
         access_token when is_binary(access_token) and access_token != "" <-
           non_empty_binary(refreshed_secret["access_token"]),
         project_id when is_binary(project_id) and project_id != "" <-
           project_id_from_secret(refreshed_secret) do
      if changed? do
        persist_secret(secret_name, refreshed_secret)
      end

      {:ok, Jason.encode!(%{"token" => access_token, "projectId" => project_id})}
    else
      :not_oauth -> :ignore
      nil -> {:error, :invalid_antigravity_secret}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_api_key_from_secret(_, _), do: {:error, :invalid_secret_value}

  defp ensure_fresh_secret(secret) when is_map(secret) do
    access_token = non_empty_binary(secret["access_token"])
    refresh_token = non_empty_binary(secret["refresh_token"])
    expires_at_ms = parse_integer(secret["expires_at_ms"])
    project_id = project_id_from_secret(secret)

    should_refresh? =
      cond do
        is_nil(refresh_token) -> false
        is_nil(project_id) -> false
        is_nil(access_token) -> true
        is_nil(expires_at_ms) -> false
        true -> near_expiry?(expires_at_ms)
      end

    if should_refresh? do
      case refresh_access_token(refresh_token, project_id) do
        {:ok, refreshed} ->
          updated =
            secret
            |> Map.put("access_token", refreshed.access_token)
            |> Map.put("refresh_token", refreshed.refresh_token)
            |> Map.put("expires_at_ms", refreshed.expires_at_ms)
            |> Map.put("project_id", refreshed.project_id)
            |> Map.put("projectId", refreshed.project_id)
            |> Map.put("updated_at_ms", System.system_time(:millisecond))

          {:ok, updated, true}

        {:error, reason} ->
          if is_binary(access_token) and access_token != "" do
            Logger.debug(
              "Google Antigravity OAuth refresh failed; using existing token: #{inspect(reason)}"
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

  defp refresh_access_token(refresh_token, project_id)
       when is_binary(refresh_token) and refresh_token != "" and is_binary(project_id) and
              project_id != "" do
    body = %{
      "client_id" => oauth_client_id(),
      "client_secret" => oauth_client_secret(),
      "refresh_token" => refresh_token,
      "grant_type" => "refresh_token"
    }

    with {:ok, data} <- post_form(@token_url, body),
         {:ok, token_data} <- parse_token_response(data) do
      {:ok,
       %{
         access_token: token_data.access_token,
         refresh_token: token_data.refresh_token || refresh_token,
         expires_at_ms: token_data.expires_at_ms,
         project_id: project_id
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

  defp build_oauth_secret(token_data, project_id, email, redirect_uri) do
    project_id = non_empty_binary(project_id) || @default_project_id

    if project_id == "" do
      {:error, :missing_project_id}
    else
      now = System.system_time(:millisecond)

      {:ok,
       %{
         "type" => @secret_type,
         "access_token" => token_data.access_token,
         "refresh_token" => token_data.refresh_token,
         "expires_at_ms" => token_data.expires_at_ms,
         "project_id" => project_id,
         "projectId" => project_id,
         "email" => non_empty_binary(email),
         "redirect_uri" => non_empty_binary(redirect_uri),
         "created_at_ms" => now,
         "updated_at_ms" => now
       }}
    end
  end

  defp persist_secret(secret_name, secret) do
    case Secrets.set(secret_name, encode_secret(secret), provider: "google_antigravity_oauth") do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.debug(
          "Failed to persist refreshed Google Antigravity OAuth secret #{secret_name}: #{inspect(reason)}"
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

  defp parse_authorization_url(value) do
    case URI.parse(value) do
      %URI{query: query} when is_binary(query) and query != "" ->
        params = URI.decode_query(query)
        %{code: params["code"], state: params["state"]}

      _ ->
        %{code: nil, state: nil}
    end
  end

  defp project_id_from_secret(secret) when is_map(secret) do
    non_empty_binary(secret["project_id"]) || non_empty_binary(secret["projectId"])
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

  defp resolve_client_credential!(secret_names, env_name, label) when is_list(secret_names) do
    value =
      Enum.find_value(secret_names, fn secret_name ->
        case Secrets.resolve(secret_name, prefer_env: false, env_fallback: false) do
          {:ok, secret_value, _source} ->
            non_empty_binary(secret_value)

          _ ->
            nil
        end
      end) || non_empty_binary(System.get_env(env_name))

    case value do
      v when is_binary(v) and v != "" ->
        v

      _ ->
        names = Enum.join(secret_names, ", ")

        raise ArgumentError,
              "Missing Google Antigravity OAuth #{label}. Store it in Lemon secrets (#{names}) or set #{env_name}."
    end
  end

  defp prompt_code(opts) do
    prompt_callback = Keyword.get(opts, :on_prompt)

    value =
      cond do
        is_function(prompt_callback, 1) ->
          prompt_callback.(%{
            message: "Paste callback URL (or authorization code):",
            placeholder: "http://localhost:51121/oauth-callback?code=..."
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

  defp non_empty_binary(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_empty_binary(_), do: nil

  defp normalize_prompt_input(value) when is_binary(value), do: String.trim(value)

  defp normalize_prompt_input(value) when is_list(value),
    do: value |> List.to_string() |> String.trim()

  defp normalize_prompt_input(_), do: ""
end
