defmodule LemonAi.Auth.GitHubCopilotOAuth do
  @moduledoc """
  GitHub Copilot OAuth helpers.

  Provides:
  - Device-code login flow (URL + user code) for onboarding
  - Copilot token refresh using stored GitHub OAuth access token
  - Secret payload encoding/decoding
  """

  import LemonAi.Auth.OAuthFlow, only: [non_empty_binary: 1]

  alias LemonAi.Auth.{OAuthFlow, OAuthSecret}

  @default_client_id_b64 "SXYxLmI1MDdhMDhjODdlY2ZlOTg="
  @default_domain "github.com"
  @default_copilot_base_url "https://api.individual.githubcopilot.com"
  @secret_type "github_copilot_oauth"
  @near_expiry_ms 5 * 60 * 1000

  @copilot_headers %{
    "User-Agent" => "GitHubCopilotChat/0.35.0",
    "Editor-Version" => "vscode/1.107.0",
    "Editor-Plugin-Version" => "copilot-chat/0.35.0",
    "Copilot-Integration-Id" => "vscode-chat"
  }

  @type oauth_secret :: %{
          required(String.t()) => String.t() | integer() | nil
        }

  @type login_opt ::
          {:enterprise_domain, String.t() | nil}
          | {:on_auth, (String.t(), String.t() | nil -> any())}
          | {:on_progress, (String.t() -> any())}
          | {:enable_models, boolean()}
          | {:sleep, (non_neg_integer() -> any())}
          | {:persist_secret,
             (String.t(), String.t(), term() -> :ok | {:ok, term()} | {:error, term()})}

  @doc """
  Run GitHub Copilot OAuth device flow.

  Returns an OAuth secret payload map suitable for `encode_secret/1`.
  """
  @spec login_device_flow([login_opt()]) :: {:ok, oauth_secret()} | {:error, term()}
  def login_device_flow(opts \\ []) when is_list(opts) do
    with {:ok, enterprise_domain} <-
           normalize_enterprise_domain(Keyword.get(opts, :enterprise_domain)),
         domain <- enterprise_domain || @default_domain,
         {:ok, device} <- start_device_flow(domain),
         :ok <- notify_auth(opts, device.verification_uri, "Enter code: #{device.user_code}"),
         {:ok, github_access_token} <-
           poll_for_github_access_token(
             domain,
             device.device_code,
             device.interval,
             device.expires_in,
             opts
           ),
         {:ok, %{token: copilot_token, expires_at_ms: expires_at_ms}} <-
           fetch_copilot_token(github_access_token, enterprise_domain) do
      secret =
        build_oauth_secret(github_access_token, copilot_token, expires_at_ms, enterprise_domain)

      maybe_enable_models(secret, opts)
      {:ok, secret}
    end
  end

  @doc false
  @spec oauth_client_id() :: String.t()
  def oauth_client_id do
    case System.get_env("GITHUB_COPILOT_CLIENT_ID") do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        @default_client_id_b64
        |> Base.decode64!()
    end
  end

  @doc """
  Encode OAuth secret payload to JSON.
  """
  @spec encode_secret(oauth_secret()) :: String.t()
  defdelegate encode_secret(secret), to: OAuthSecret, as: :encode

  @doc """
  Resolve a usable Copilot API key from a secret value.

  - Returns `:ignore` for non-Copilot-OAuth payloads.
  - Returns `{:ok, api_key}` for valid payloads (refreshing/persisting when needed).
  - Returns `{:error, reason}` when payload is Copilot OAuth but unusable.
  """
  @spec resolve_api_key_from_secret(String.t(), String.t()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  def resolve_api_key_from_secret(secret_name, secret_value, opts \\ [])
      when is_binary(secret_name) and is_binary(secret_value) do
    OAuthSecret.resolve(__MODULE__, secret_name, secret_value, opts, %{
      refresh: &refresh_secret/1,
      skew_ms: @near_expiry_ms,
      always_reload: true,
      refresh_replaced: true,
      usable: &OAuthSecret.usable/1,
      resolve: &OAuthSecret.access_token/1
    })
  end

  @doc """
  Normalize GitHub domain input (`company.ghe.com` or `https://company.ghe.com`).
  Returns hostname or `nil` for blank/invalid values.
  """
  @spec normalize_domain(String.t()) :: String.t() | nil
  def normalize_domain(input) when is_binary(input) do
    trimmed = String.trim(input)

    cond do
      trimmed == "" ->
        nil

      true ->
        raw = if String.contains?(trimmed, "://"), do: trimmed, else: "https://#{trimmed}"

        case URI.parse(raw) do
          %URI{host: host} when is_binary(host) and host != "" -> host
          _ -> nil
        end
    end
  end

  # ----------------------------------------------------------------------------
  # Device flow
  # ----------------------------------------------------------------------------

  defp start_device_flow(domain) do
    urls = github_urls(domain)

    body = %{
      "client_id" => oauth_client_id(),
      "scope" => "read:user"
    }

    headers = %{
      "accept" => "application/json",
      "content-type" => "application/json",
      "user-agent" => @copilot_headers["User-Agent"]
    }

    with {:ok, data} <- post_json(urls.device_code_url, body, headers),
         {:ok, device} <- parse_device_code_response(data) do
      {:ok, device}
    end
  end

  # RFC 8628 polling via OAuthFlow: honors interval and slow_down, stops at
  # expiry; `opts[:sleep]` makes it deterministic under test.
  defp poll_for_github_access_token(domain, device_code, interval_s, expires_in_s, opts) do
    notify_progress(opts, "Waiting for browser authentication...")

    url = github_urls(domain).access_token_url

    body = %{
      "client_id" => oauth_client_id(),
      "device_code" => device_code,
      "grant_type" => "urn:ietf:params:oauth:grant-type:device_code"
    }

    headers = %{
      "accept" => "application/json",
      "content-type" => "application/json",
      "user-agent" => @copilot_headers["User-Agent"]
    }

    poll = fn ->
      case OAuthFlow.request(url, json: body, headers: headers) do
        {:ok, response} -> OAuthFlow.classify_device_token_response(response)
        {:error, _} = error -> error
      end
    end

    poll_opts =
      [interval_s: interval_s, expires_in_s: expires_in_s] ++ Keyword.take(opts, [:sleep])

    with {:ok, token_body} <- OAuthFlow.poll_device_token(poll, poll_opts) do
      case non_empty_binary(token_body["access_token"]) do
        nil -> {:error, :device_flow_invalid_response}
        access_token -> {:ok, access_token}
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Secret resolution / refresh
  # ----------------------------------------------------------------------------

  @doc "Decode a stored Copilot OAuth payload; `:not_oauth` for other values."
  @spec decode_secret(term()) :: {:ok, oauth_secret()} | :not_oauth
  def decode_secret(value), do: OAuthSecret.decode(value, [@secret_type])

  defp refresh_secret(secret) do
    with {:ok, %{token: token, expires_at_ms: expires_at_ms}} <-
           fetch_copilot_token(
             non_empty_binary(secret["refresh_token"]),
             non_empty_binary(secret["enterprise_domain"])
           ) do
      {:ok,
       secret
       |> Map.put("access_token", token)
       |> Map.put("expires_at_ms", expires_at_ms)
       |> Map.put("base_url", copilot_base_url(token, secret["enterprise_domain"]))
       |> Map.put("updated_at_ms", System.system_time(:millisecond))}
    end
  end

  # ----------------------------------------------------------------------------
  # Copilot token / model enablement
  # ----------------------------------------------------------------------------

  defp fetch_copilot_token(refresh_token, enterprise_domain) when is_binary(refresh_token) do
    domain = enterprise_domain || @default_domain
    urls = github_urls(domain)

    headers =
      Map.merge(
        %{
          "accept" => "application/json",
          "authorization" => "Bearer #{refresh_token}"
        },
        normalize_headers(@copilot_headers)
      )

    case LemonAi.Auth.OAuthFlow.request(urls.copilot_token_url, method: :get, headers: headers) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        token = body_value(body, "token")
        expires_at = body_value(body, "expires_at") |> parse_integer()

        cond do
          !is_binary(token) or token == "" ->
            {:error, :invalid_copilot_token_response}

          !is_integer(expires_at) ->
            {:error, :invalid_copilot_expiry}

          true ->
            {:ok, %{token: token, expires_at_ms: expires_at * 1000 - @near_expiry_ms}}
        end

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, :reauth_required}

      {:ok, %{status: status, body: body}} ->
        {:error, {:copilot_token_http_error, LemonAi.Auth.OAuthFlow.http_error(status, body)}}

      {:error, _} = error ->
        error
    end
  end

  defp maybe_enable_models(secret, opts) do
    if Keyword.get(opts, :enable_models, true) do
      notify_progress(opts, "Enabling Copilot models...")

      model_ids =
        :github_copilot
        |> LemonAi.Models.get_models()
        |> Enum.map(& &1.id)
        |> Enum.uniq()

      token = secret["access_token"]
      enterprise_domain = secret["enterprise_domain"]

      {ok_count, total_count} =
        model_ids
        |> Task.async_stream(
          fn model_id -> enable_model(token, model_id, enterprise_domain) end,
          max_concurrency: 4,
          timeout: 15_000,
          ordered: false
        )
        |> Enum.reduce({0, 0}, fn
          {:ok, true}, {ok, total} -> {ok + 1, total + 1}
          {:ok, false}, {ok, total} -> {ok, total + 1}
          {:exit, _}, {ok, total} -> {ok, total + 1}
        end)

      notify_progress(opts, "Enabled #{ok_count}/#{total_count} Copilot models.")
    end
  end

  defp enable_model(token, model_id, enterprise_domain)
       when is_binary(token) and is_binary(model_id) do
    base_url = copilot_base_url(token, enterprise_domain)
    url = "#{String.trim_trailing(base_url, "/")}/models/#{URI.encode(model_id)}/policy"

    headers =
      Map.merge(
        %{
          "authorization" => "Bearer #{token}",
          "content-type" => "application/json",
          "openai-intent" => "chat-policy",
          "x-interaction-type" => "chat-policy"
        },
        normalize_headers(@copilot_headers)
      )

    case Req.post(url,
           headers: headers,
           json: %{"state" => "enabled"},
           redirect: false,
           retry: false
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> true
      _ -> false
    end
  end

  defp enable_model(_token, _model_id, _enterprise_domain), do: false

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp build_oauth_secret(refresh_token, access_token, expires_at_ms, enterprise_domain) do
    %{
      "type" => @secret_type,
      "refresh_token" => refresh_token,
      "access_token" => access_token,
      "expires_at_ms" => expires_at_ms,
      "enterprise_domain" => enterprise_domain,
      "base_url" => copilot_base_url(access_token, enterprise_domain),
      "updated_at_ms" => System.system_time(:millisecond)
    }
  end

  defp copilot_base_url(token, enterprise_domain) do
    token
    |> base_url_from_token()
    |> case do
      nil when is_binary(enterprise_domain) and enterprise_domain != "" ->
        "https://copilot-api.#{enterprise_domain}"

      nil ->
        @default_copilot_base_url

      url ->
        url
    end
  end

  defp base_url_from_token(token) when is_binary(token) do
    case Regex.run(~r/proxy-ep=([^;]+)/, token) do
      [_, proxy_host] ->
        api_host = String.replace(proxy_host, ~r/^proxy\./, "api.")
        "https://#{api_host}"

      _ ->
        nil
    end
  end

  defp base_url_from_token(_), do: nil

  defp normalize_enterprise_domain(nil), do: {:ok, nil}

  defp normalize_enterprise_domain(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:ok, nil}
      domain = normalize_domain(trimmed) -> {:ok, domain}
      true -> {:error, :invalid_enterprise_domain}
    end
  end

  defp normalize_enterprise_domain(_), do: {:error, :invalid_enterprise_domain}

  defp github_urls(domain) do
    %{
      device_code_url: "https://#{domain}/login/device/code",
      access_token_url: "https://#{domain}/login/oauth/access_token",
      copilot_token_url: "https://api.#{domain}/copilot_internal/v2/token"
    }
  end

  defp parse_device_code_response(data) when is_map(data) do
    device_code = body_value(data, "device_code")
    user_code = body_value(data, "user_code")
    verification_uri = body_value(data, "verification_uri")
    interval = body_value(data, "interval") |> parse_integer()
    expires_in = body_value(data, "expires_in") |> parse_integer()

    if is_binary(device_code) and device_code != "" and
         is_binary(user_code) and user_code != "" and
         is_binary(verification_uri) and verification_uri != "" and
         is_integer(interval) and interval > 0 and
         is_integer(expires_in) and expires_in > 0 do
      {:ok,
       %{
         device_code: device_code,
         user_code: user_code,
         verification_uri: verification_uri,
         interval: interval,
         expires_in: expires_in
       }}
    else
      {:error, {:invalid_device_code_response, data}}
    end
  end

  defp parse_device_code_response(other), do: {:error, {:invalid_device_code_response, other}}

  defp post_json(url, body, headers) do
    case LemonAi.Auth.OAuthFlow.request(url, json: body, headers: headers) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        {:error, LemonAi.Auth.OAuthFlow.http_error(status, response_body)}

      {:error, _} = error ->
        error
    end
  end

  defp notify_auth(opts, url, instructions) do
    if callback = Keyword.get(opts, :on_auth) do
      callback.(url, instructions)
    end

    :ok
  end

  defp notify_progress(opts, message) do
    if callback = Keyword.get(opts, :on_progress) do
      callback.(message)
    end

    :ok
  end

  defp normalize_headers(headers) when is_map(headers) do
    headers
    |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), v} end)
    |> Map.new()
  end

  defp body_value(body, key) when is_map(body) do
    case Map.fetch(body, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(body, fn
          {k, value} when is_atom(k) ->
            if Atom.to_string(k) == key, do: value, else: nil

          _ ->
            nil
        end)
    end
  end

  defp body_value(_body, _key), do: nil

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_float(value), do: trunc(value)

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil
end
