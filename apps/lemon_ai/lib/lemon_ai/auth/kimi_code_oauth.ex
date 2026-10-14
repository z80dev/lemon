defmodule LemonAi.Auth.KimiCodeOAuth do
  @moduledoc """
  Kimi Code subscription sign-in through the device authorization grant.

  `login_device_flow/1` requests a device code from `auth.kimi.com`, shows the
  verification URL and user code through `:on_auth`, polls until the user
  approves, and returns a refreshable secret payload for the `kimi_coding`
  provider. `KIMI_CODE_OAUTH_HOST` (or `KIMI_OAUTH_HOST`) and the `:base_url`
  option override the auth host.

  Kimi identifies clients by a Kimi CLI fingerprint: `request_headers/0` is sent
  with every auth request and, by `LemonAi.Providers.Anthropic`, with model
  requests that carry an OAuth access token (`oauth_token?/1`). The device id
  is derived from the host name and home directory, so it is stable across runs
  without writing state.

  `resolve_api_key_from_secret/3` refreshes five minutes before expiry or on
  `force_refresh: true`; see `LemonAi.Auth.OAuthFlow` for locking and
  persistence. Tests may pass `:req_options` and `:sleep`.
  """

  alias LemonAi.Auth.OAuthFlow

  @client_id "17e5f671-d194-4dfb-9706-5516cb48c098"
  @default_base_url "https://auth.kimi.com"
  @host_env_vars ["KIMI_CODE_OAUTH_HOST", "KIMI_OAUTH_HOST"]
  @secret_type "kimi_code_oauth"
  @refresh_skew_ms 5 * 60 * 1000
  # Kimi gates on the Kimi CLI fingerprint; pin a released Kimi CLI version.
  @kimi_cli_version "1.52.0"

  @type oauth_secret :: %{required(String.t()) => String.t() | integer() | nil}

  @doc """
  Sign in with the device authorization grant.

  Requires `:on_auth`. Optional: `:on_progress`, `:base_url`, `:sleep`,
  `:req_options`. Returns the secret payload; callers own storage.
  """
  @spec login_device_flow(keyword()) :: {:ok, oauth_secret()} | {:error, term()}
  def login_device_flow(opts \\ []) when is_list(opts) do
    base = base_url(opts)

    with :ok <- OAuthFlow.notify_progress(opts, "Requesting Kimi device authorization..."),
         {:ok, response} <-
           OAuthFlow.request(
             base <> "/api/oauth/device_authorization",
             [form: %{"client_id" => @client_id}, headers: request_headers()],
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
         {:ok, body} <- poll(base, device, opts),
         {:ok, token} <- OAuthFlow.parse_token_response(body) do
      now = System.system_time(:millisecond)

      {:ok,
       %{
         "type" => @secret_type,
         "access_token" => token.access_token,
         "refresh_token" => token.refresh_token,
         "expires_at_ms" => token.expires_at_ms,
         "created_at_ms" => now,
         "updated_at_ms" => now
       }
       |> put_present("account_id", account_id(token.access_token))}
    end
  end

  defp poll(base, device, opts) do
    body = %{
      "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
      "client_id" => @client_id,
      "device_code" => device.device_code
    }

    OAuthFlow.poll_device_token(
      fn ->
        case OAuthFlow.request(
               base <> "/api/oauth/token",
               [form: body, headers: request_headers()],
               opts
             ) do
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

  @doc "Decode a stored Kimi Code OAuth payload."
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
      expires_at_ms: OAuthFlow.parse_integer(secret["expires_at_ms"]),
      signed_in_at_ms: OAuthFlow.parse_integer(secret["created_at_ms"])
    }
  end

  @doc """
  Resolve a usable access token from a stored payload; `:ignore` for other values.
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
  Whether a credential is a Kimi OAuth access token (a JWT) rather than a
  Kimi API key (`sk-…`).
  """
  @spec oauth_token?(term()) :: boolean()
  def oauth_token?(token) when is_binary(token) do
    not String.starts_with?(token, "sk-") and OAuthFlow.jwt_claims(token) != nil
  end

  def oauth_token?(_), do: false

  @doc "Kimi CLI fingerprint headers (lower-case names)."
  @spec request_headers() :: [{String.t(), String.t()}]
  def request_headers do
    key = {__MODULE__, :request_headers}

    case :persistent_term.get(key, nil) do
      nil ->
        headers = build_request_headers()
        :persistent_term.put(key, headers)
        headers

      headers ->
        headers
    end
  end

  # ── Refresh ────────────────────────────────────────────────────────────────

  defp refresh_secret(secret, opts) do
    refresh_token = OAuthFlow.non_empty_binary(secret["refresh_token"])

    body = %{
      "grant_type" => "refresh_token",
      "client_id" => @client_id,
      "refresh_token" => refresh_token
    }

    with {:ok, response} <-
           OAuthFlow.request(
             base_url(opts) <> "/api/oauth/token",
             [form: body, headers: request_headers()],
             opts
           ),
         {:ok, token} <- OAuthFlow.refresh_response(response, refresh_token) do
      {:ok,
       secret
       |> Map.put("access_token", token.access_token)
       |> Map.put("refresh_token", token.refresh_token)
       |> Map.put("expires_at_ms", token.expires_at_ms)
       |> Map.put("updated_at_ms", System.system_time(:millisecond))
       |> put_present("account_id", account_id(token.access_token))}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp base_url(opts) do
    (Keyword.get(opts, :base_url) ||
       Enum.find_value(@host_env_vars, &OAuthFlow.non_empty_binary(System.get_env(&1))) ||
       @default_base_url)
    |> String.trim_trailing("/")
  end

  defp account_id(access_token) do
    access_token |> OAuthFlow.jwt_claims() |> OAuthFlow.claim(["user_id", "sub"])
  end

  defp build_request_headers do
    hostname = hostname()

    [
      {"user-agent", "KimiCLI/#{@kimi_cli_version}"},
      {"x-msh-platform", "kimi_cli"},
      {"x-msh-version", @kimi_cli_version},
      {"x-msh-device-name", sanitize(hostname)},
      {"x-msh-device-model", sanitize(device_model())},
      {"x-msh-os-version", sanitize(os_version())},
      {"x-msh-device-id", device_id(hostname)}
    ]
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "unknown"
    end
  end

  defp device_model do
    arch =
      case :erlang.system_info(:system_architecture) |> to_string() |> String.split("-") do
        ["aarch64" | _] -> "arm64"
        ["x86_64" | _] -> "x64"
        [arch | _] -> arch
      end

    system =
      case :os.type() do
        {:unix, :darwin} -> "macOS"
        {:unix, :linux} -> "Linux"
        {:win32, _} -> "Windows"
        {_, other} -> to_string(other)
      end

    Enum.join([system, os_version(), arch], " ")
  end

  defp os_version do
    case :os.version() do
      {major, minor, patch} -> "#{major}.#{minor}.#{patch}"
      other when is_list(other) -> to_string(other)
      _ -> "unknown"
    end
  end

  defp device_id(hostname) do
    home = System.user_home() || ""

    :crypto.hash(:sha256, "lemon-kimi-device:#{hostname}:#{home}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  # Header values must be printable ASCII.
  defp sanitize(value) do
    case value |> String.replace(~r/[^\x20-\x7E]/, "") |> String.trim() do
      "" -> "unknown"
      sanitized -> sanitized
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
