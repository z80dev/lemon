defmodule LemonAi.Auth.ZaiOAuth do
  @moduledoc """
  Z.AI GLM Coding Plan sign-in that provisions a durable API key.

  Mirrors ZCode's desktop sign-in: an authorization-code request (no PKCE) on
  `chat.z.ai`, then a JSON token exchange on `zcode.z.ai` that returns a
  short-lived OAuth access token. Z.AI only accepts ZCode's
  `zcode://zai-auth/callback` redirect for this client, which Lemon cannot
  receive, so `login_device_flow/1` asks for the final redirect URL (or code)
  through `:on_prompt`.

  The OAuth token is then exchanged at the business-login endpoint, and the
  business APIs find or create an API key named `lemon` in the account's
  default organization/project. The result is that durable `id.secret` key,
  returned as `{:ok, api_key}` for storage like a pasted key; nothing refreshes.

  The endpoints honor omp-compatible overrides: `ZAI_OAUTH_CLIENT_ID`,
  `ZAI_OAUTH_AUTHORIZE_URL`, `ZAI_OAUTH_REDIRECT_URI`, `ZAI_OAUTH_TOKEN_URL`,
  `ZAI_BIZ_BASE` and `ZAI_BUSINESS_LOGIN_URL`, or the matching options
  `:client_id`, `:authorize_url`, `:redirect_uri`, `:token_url`, `:biz_base_url`
  and `:business_login_url`. Tests may pass `:req_options` and `:state`.
  """

  alias LemonAi.Auth.OAuthFlow

  @client_id "client_P8X5CMWmlaRO9gyO-KSqtg"
  @authorize_url "https://chat.z.ai/api/oauth/authorize"
  @redirect_uri "zcode://zai-auth/callback"
  @token_url "https://zcode.z.ai/api/v1/oauth/token"
  @biz_base_url "https://api.z.ai"
  @business_login_url "https://api.z.ai/api/auth/z/login"
  @key_name "lemon"

  @doc "Build the authorization URL and state."
  @spec build_authorize_url(keyword()) :: {:ok, map()}
  def build_authorize_url(opts \\ []) do
    redirect_uri = setting(opts, :redirect_uri, "ZAI_OAUTH_REDIRECT_URI", @redirect_uri)

    state =
      Keyword.get(opts, :state) || Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    query =
      URI.encode_query(
        [
          {"client_id", setting(opts, :client_id, "ZAI_OAUTH_CLIENT_ID", @client_id)},
          {"response_type", "code"},
          {"redirect_uri", redirect_uri},
          {"state", state}
        ],
        :rfc3986
      )

    authorize_url = setting(opts, :authorize_url, "ZAI_OAUTH_AUTHORIZE_URL", @authorize_url)

    {:ok, %{authorize_url: "#{authorize_url}?#{query}", state: state, redirect_uri: redirect_uri}}
  end

  @doc """
  Sign in and return `{:ok, api_key}`. Requires `:on_auth` and `:on_prompt`.
  """
  @spec login_device_flow(keyword()) :: {:ok, String.t()} | {:error, term()}
  def login_device_flow(opts \\ []) when is_list(opts) do
    {:ok, auth} = build_authorize_url(opts)

    instructions =
      "Sign in to Z.AI in your browser. The browser then tries to open ZCode " <>
        "(zcode://...); copy that final address or the code from the address bar."

    with :ok <- OAuthFlow.notify_auth(opts, auth.authorize_url, instructions),
         {:ok, input} <- prompt(opts),
         {:ok, %{code: code, state: state}} <- parse_authorization_input(input),
         :ok <- ensure_state(auth.state, state),
         :ok <- OAuthFlow.notify_progress(opts, "Exchanging the authorization code..."),
         {:ok, access_token} <- exchange_code(code, auth.state, auth.redirect_uri, opts),
         :ok <-
           OAuthFlow.notify_progress(opts, "Provisioning a Z.AI API key named #{@key_name}...") do
      mint_api_key(access_token, opts)
    end
  end

  @doc """
  Parse a pasted redirect URL, `code=` query string, `code#state`, or bare code.
  """
  @spec parse_authorization_input(String.t()) ::
          {:ok, %{code: String.t(), state: String.t() | nil}} | {:error, term()}
  def parse_authorization_input(input) when is_binary(input) do
    value = String.trim(input)

    {code, state} =
      cond do
        String.contains?(value, "://") ->
          case URI.parse(value) do
            %URI{query: query} when is_binary(query) ->
              params = URI.decode_query(query)
              {params["code"], params["state"]}

            _ ->
              {nil, nil}
          end

        String.contains?(value, "code=") ->
          params = URI.decode_query(value)
          {params["code"], params["state"]}

        String.contains?(value, "#") ->
          [code, state] = String.split(value, "#", parts: 2)
          {code, state}

        true ->
          {value, nil}
      end

    case OAuthFlow.non_empty_binary(code) do
      nil -> {:error, :missing_authorization_code}
      code -> {:ok, %{code: code, state: OAuthFlow.non_empty_binary(state)}}
    end
  end

  @doc "Exchange an authorization code for the short-lived Z.AI OAuth access token."
  @spec exchange_code(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def exchange_code(code, state, redirect_uri, opts \\ []) do
    body = %{
      "provider" => "zai",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "state" => state
    }

    url = setting(opts, :token_url, "ZAI_OAUTH_TOKEN_URL", @token_url)

    with {:ok, response} <- OAuthFlow.request(url, [json: body], opts),
         {:ok, %{} = body} <- unwrap(response, :token_exchange) do
      case OAuthFlow.non_empty_binary(get_in(body, ["data", "zai", "access_token"])) do
        nil -> {:error, :missing_access_token}
        token -> {:ok, token}
      end
    end
  end

  @doc """
  Provision the durable API key: business login, default organization and
  project, find or create the `lemon` key, then read its secret.
  """
  @spec mint_api_key(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def mint_api_key(oauth_access_token, opts \\ []) do
    base = setting(opts, :biz_base_url, "ZAI_BIZ_BASE", @biz_base_url)
    login_url = setting(opts, :business_login_url, "ZAI_BUSINESS_LOGIN_URL", @business_login_url)

    with {:ok, response} <-
           OAuthFlow.request(login_url, [json: %{"token" => oauth_access_token}], opts),
         {:ok, login} <- unwrap_data(response, :business_login),
         {:ok, biz_token} <- biz_token(login),
         auth = [{"authorization", "Bearer #{biz_token}"}],
         {:ok, customer} <-
           get(base <> "/api/biz/customer/getCustomerInfo", auth, opts, :customer),
         {:ok, org_id, project_id} <- default_project(customer),
         keys_url =
           "#{base}/api/biz/v1/organization/#{URI.encode(org_id)}/projects/#{URI.encode(project_id)}/api_keys",
         {:ok, keys} <- get(keys_url, auth, opts, :api_key_list),
         {:ok, record} <- find_or_create_key(keys, keys_url, auth, opts),
         {:ok, api_key} <- string_field(record, "apiKey", :missing_api_key),
         {:ok, copied} <-
           get(
             "#{keys_url}/copy/#{URI.encode(api_key, &URI.char_unreserved?/1)}",
             auth,
             opts,
             :api_key_copy
           ),
         {:ok, secret_key} <- string_field(copied, "secretKey", :missing_secret_key) do
      {:ok, "#{api_key}.#{secret_key}"}
    end
  end

  # ── Business API helpers ───────────────────────────────────────────────────

  defp biz_token(login) do
    case OAuthFlow.non_empty_binary(login["access_token"]) ||
           OAuthFlow.non_empty_binary(login["accessToken"]) do
      nil -> {:error, :missing_business_token}
      token -> {:ok, token}
    end
  end

  defp default_project(customer) do
    orgs = list(customer["organizations"])
    org = Enum.find(orgs, & &1["isDefault"]) || List.first(orgs) || %{}
    projects = list(org["projects"])
    project = Enum.find(projects, & &1["isDefault"]) || List.first(projects) || %{}

    case {scalar(org["organizationId"]), scalar(project["projectId"])} do
      {org_id, project_id} when is_binary(org_id) and is_binary(project_id) ->
        {:ok, org_id, project_id}

      _ ->
        {:error, :no_zai_project}
    end
  end

  defp find_or_create_key(keys, keys_url, auth, opts) do
    case Enum.find(key_list(keys), &(&1["name"] == @key_name)) do
      %{} = existing ->
        {:ok, existing}

      nil ->
        with {:ok, response} <-
               OAuthFlow.request(keys_url, [json: %{"name" => @key_name}, headers: auth], opts) do
          unwrap_data(response, :api_key_create)
        end
    end
  end

  defp key_list(value) when is_list(value), do: Enum.filter(value, &is_map/1)

  defp key_list(%{} = value) do
    Enum.find_value(["list", "keys", "apiKeys", "records"], [], fn field ->
      if is_list(value[field]), do: key_list(value[field])
    end)
  end

  defp key_list(_), do: []

  defp get(url, auth, opts, operation) do
    with {:ok, response} <- OAuthFlow.request(url, [method: :get, headers: auth], opts) do
      unwrap_data(response, operation)
    end
  end

  defp unwrap_data(response, operation) do
    with {:ok, body} <- unwrap(response, operation) do
      case body do
        %{"data" => data} when is_map(data) or is_list(data) -> {:ok, data}
        %{"data" => _} -> {:error, {:zai_request_failed, operation, :missing_data}}
        other -> {:ok, other}
      end
    end
  end

  # Z.AI wraps results in `{code, msg, data, success}`: the OAuth endpoint
  # succeeds with code 0, the business APIs with 200 / success: true.
  defp unwrap(%{status: status, body: body}, operation) when status in 200..299 do
    cond do
      not is_map(body) and not is_list(body) ->
        {:error, {:zai_request_failed, operation, :invalid_response}}

      is_map(body) and (body["success"] == false or not success_code?(body["code"])) ->
        {:error, {:zai_request_failed, operation, body["code"]}}

      true ->
        {:ok, body}
    end
  end

  defp unwrap(%{status: status}, operation),
    do: {:error, {:zai_request_failed, operation, {:http_error, status}}}

  defp success_code?(nil), do: true
  defp success_code?(code) when code in [0, 200, "0", "200"], do: true
  defp success_code?(_), do: false

  defp string_field(map, key, error) when is_map(map) do
    case OAuthFlow.non_empty_binary(map[key]) do
      nil -> {:error, error}
      value -> {:ok, value}
    end
  end

  defp string_field(_, _key, error), do: {:error, error}

  defp scalar(value) when is_binary(value), do: OAuthFlow.non_empty_binary(value)
  defp scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp scalar(_), do: nil

  defp list(value) when is_list(value), do: Enum.filter(value, &is_map/1)
  defp list(_), do: []

  # ── Login helpers ──────────────────────────────────────────────────────────

  defp prompt(opts) do
    case Keyword.get(opts, :on_prompt) do
      prompt when is_function(prompt, 1) ->
        message = "Paste the final redirect URL (zcode://zai-auth/callback?code=...) or the code:"

        case prompt.(%{message: message, placeholder: "zcode://zai-auth/callback?code=..."})
             |> OAuthFlow.normalize_prompt_input() do
          "" -> {:error, :login_cancelled}
          value -> {:ok, value}
        end

      _ ->
        {:error, :prompt_callback_required}
    end
  end

  defp ensure_state(_expected, nil), do: :ok
  defp ensure_state(expected, expected), do: :ok
  defp ensure_state(_expected, _provided), do: {:error, :oauth_state_mismatch}

  defp setting(opts, key, env_var, default) do
    Keyword.get(opts, key) || OAuthFlow.non_empty_binary(System.get_env(env_var)) || default
  end
end
