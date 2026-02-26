defmodule Ai.Auth.GitHubCopilotOAuth do
  @moduledoc """
  GitHub Copilot OAuth helpers.

  Provides:
  - Device-code login flow (URL + user code) for onboarding
  - Copilot token refresh using stored GitHub OAuth access token
  - Secret payload encoding/decoding for encrypted Lemon secrets storage
  """

  require Logger

  alias LemonCore.Secrets

  @client_id "Iv1.b507a08c87ecfe98"
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

  @doc """
  Run GitHub Copilot OAuth device flow.

  Returns an OAuth secret payload map suitable for `encode_secret/1` and
  storage in `LemonCore.Secrets`.
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
           fetch_copilot_token(github_access_token, enterprise_domain),
         {:ok, secret} <-
           build_oauth_secret(
             github_access_token,
             copilot_token,
             expires_at_ms,
             enterprise_domain
           ) do
      maybe_enable_models(secret, opts)
      {:ok, secret}
    end
  end

  @doc """
  Encode OAuth secret payload to JSON for encrypted secret storage.
  """
  @spec encode_secret(oauth_secret()) :: String.t()
  def encode_secret(secret) when is_map(secret) do
    Jason.encode!(secret)
  end

  @doc """
  Resolve a usable Copilot API key from a secret value.

  - Returns `:ignore` for non-Copilot-OAuth payloads.
  - Returns `{:ok, api_key}` for valid payloads (refreshing/persisting when needed).
  - Returns `{:error, reason}` when payload is Copilot OAuth but unusable.
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
      "client_id" => @client_id,
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

  defp poll_for_github_access_token(domain, device_code, interval_s, expires_in_s, opts) do
    notify_progress(opts, "Waiting for browser authentication...")

    urls = github_urls(domain)
    deadline_ms = System.system_time(:millisecond) + expires_in_s * 1000
    interval_ms = max(1000, trunc(interval_s * 1000))
    do_poll_access_token(urls.access_token_url, device_code, interval_ms, deadline_ms)
  end

  defp do_poll_access_token(url, device_code, interval_ms, deadline_ms) do
    if System.system_time(:millisecond) >= deadline_ms do
      {:error, :device_flow_timed_out}
    else
      body = %{
        "client_id" => @client_id,
        "device_code" => device_code,
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code"
      }

      headers = %{
        "accept" => "application/json",
        "content-type" => "application/json",
        "user-agent" => @copilot_headers["User-Agent"]
      }

      case post_json(url, body, headers) do
        {:ok, %{"access_token" => access_token}}
        when is_binary(access_token) and access_token != "" ->
          {:ok, access_token}

        {:ok, %{"error" => "authorization_pending"}} ->
          Process.sleep(interval_ms)
          do_poll_access_token(url, device_code, interval_ms, deadline_ms)

        {:ok, %{"error" => "slow_down"}} ->
          next_interval = interval_ms + 5_000
          Process.sleep(next_interval)
          do_poll_access_token(url, device_code, next_interval, deadline_ms)

        {:ok, %{"error" => error}} when is_binary(error) ->
          {:error, {:device_flow_error, error}}

        {:ok, other} ->
          {:error, {:device_flow_invalid_response, other}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Secret resolution / refresh
  # ----------------------------------------------------------------------------

  defp decode_secret(secret_value) do
    with {:ok, decoded} <- Jason.decode(secret_value),
         true <- is_map(decoded),
         true <- decoded["type"] == @secret_type do
      {:ok, decoded}
    else
      _ -> :not_oauth
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
      case fetch_copilot_token(refresh_token, non_empty_binary(secret["enterprise_domain"])) do
        {:ok, %{token: token, expires_at_ms: refreshed_expires_at_ms}} ->
          updated =
            secret
            |> Map.put("access_token", token)
            |> Map.put("expires_at_ms", refreshed_expires_at_ms)
            |> Map.put("base_url", copilot_base_url(token, secret["enterprise_domain"]))
            |> Map.put("updated_at_ms", System.system_time(:millisecond))

          {:ok, updated, true}

        {:error, reason} ->
          if is_binary(access_token) and access_token != "" do
            Logger.debug(
              "GitHub Copilot refresh failed; using existing token: #{inspect(reason)}"
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

  defp persist_secret(secret_name, secret) do
    case Secrets.set(secret_name, encode_secret(secret), provider: "github_copilot_oauth") do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.debug(
          "Failed to persist refreshed GitHub Copilot secret #{secret_name}: #{inspect(reason)}"
        )

        :ok
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

    case Req.get(urls.copilot_token_url, headers: headers) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        token = body_value(body, "token")
        expires_at = body_value(body, "expires_at") |> parse_integer()

        cond do
          !is_binary(token) or token == "" ->
            {:error, {:invalid_copilot_token_response, body}}

          !is_integer(expires_at) ->
            {:error, {:invalid_copilot_expiry, body}}

          true ->
            {:ok, %{token: token, expires_at_ms: expires_at * 1000 - @near_expiry_ms}}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:copilot_token_http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_enable_models(secret, opts) do
    if Keyword.get(opts, :enable_models, true) do
      notify_progress(opts, "Enabling Copilot models...")

      model_ids =
        :github_copilot
        |> Ai.Models.get_models()
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

    case Req.post(url, headers: headers, json: %{"state" => "enabled"}) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> true
      _ -> false
    end
  end

  defp enable_model(_token, _model_id, _enterprise_domain), do: false

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp build_oauth_secret(refresh_token, access_token, expires_at_ms, enterprise_domain) do
    if is_binary(refresh_token) and refresh_token != "" and
         is_binary(access_token) and access_token != "" and is_integer(expires_at_ms) do
      {:ok,
       %{
         "type" => @secret_type,
         "refresh_token" => refresh_token,
         "access_token" => access_token,
         "expires_at_ms" => expires_at_ms,
         "enterprise_domain" => enterprise_domain,
         "base_url" => copilot_base_url(access_token, enterprise_domain),
         "updated_at_ms" => System.system_time(:millisecond)
       }}
    else
      {:error, :invalid_oauth_secret_fields}
    end
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

  defp near_expiry?(expires_at_ms) when is_integer(expires_at_ms) do
    System.system_time(:millisecond) + @near_expiry_ms >= expires_at_ms
  end

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
    case Req.post(url, json: body, headers: headers) do
      {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:http_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
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

  defp non_empty_binary(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_empty_binary(_), do: nil
end
