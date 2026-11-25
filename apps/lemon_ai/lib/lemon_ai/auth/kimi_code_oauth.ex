defmodule LemonAi.Auth.KimiCodeOAuth do
  @moduledoc """
  Kimi Code subscription sign-in through the device authorization grant.

  `login_device_flow/1` requests a device code from the Kimi Code auth host,
  shows the verification URL and user code through `:on_auth`, polls until the
  user approves, and returns a refreshable secret payload for the `kimi_coding`
  provider. The auth host is the `:base_url` option, else the `:region`
  option's host (`region/1`: `auth.kimi.com` for `"china"`, `auth.kimi.ai` for
  `"global"`), else `KIMI_CODE_OAUTH_HOST` (or `KIMI_OAUTH_HOST`), else
  `auth.kimi.com`. The payload records that host as `auth_base_url`, and
  refreshes use it, because Kimi Code tokens belong to the deployment that
  issued them.

  Kimi identifies clients by a Kimi CLI fingerprint: `request_headers/0` is sent
  with every auth request and, by `LemonAi.Providers.Anthropic`, with every
  Kimi Code model request (API key or OAuth). The device id is persisted at
  `~/.lemon/kimi-device-id` (mode 0600), as omp persists its own; see
  `device_id/1`.

  `resolve_api_key_from_secret/3` refreshes five minutes before expiry or on
  `force_refresh: true`; see `LemonAi.Auth.OAuthFlow` for locking and
  persistence. Tests may pass `:req_options` and `:sleep`.
  """

  alias LemonAi.Auth.{Cache, OAuthFlow, OAuthSecret}

  @client_id "17e5f671-d194-4dfb-9706-5516cb48c098"
  @default_base_url "https://auth.kimi.com"
  @regions %{
    "china" => %{
      auth_base_url: "https://auth.kimi.com",
      api_base_url: "https://api.kimi.com/coding",
      omp_provider: "kimi-code"
    },
    "global" => %{
      auth_base_url: "https://auth.kimi.ai",
      api_base_url: "https://api.kimi.ai/coding",
      omp_provider: "kimi-code-global"
    }
  }
  @host_env_vars ["KIMI_CODE_OAUTH_HOST", "KIMI_OAUTH_HOST"]
  @secret_type "kimi_code_oauth"
  @refresh_skew_ms 5 * 60 * 1000
  # Kimi gates on the Kimi CLI fingerprint; pin a released Kimi CLI version.
  @kimi_cli_version "1.52.0"
  @device_id_file "kimi-device-id"

  @type oauth_secret :: %{required(String.t()) => String.t() | integer() | nil}

  @doc """
  Sign in with the device authorization grant.

  Requires `:on_auth`. Optional: `:on_progress`, `:base_url`, `:region`,
  `:sleep`, `:req_options`. Returns the secret payload; callers own storage.
  """
  @spec login_device_flow(keyword()) :: {:ok, oauth_secret()} | {:error, term()}
  def login_device_flow(opts \\ []) when is_list(opts) do
    with {:ok, base} <- login_base_url(opts),
         :ok <- OAuthFlow.notify_progress(opts, "Requesting Kimi device authorization..."),
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
         "auth_base_url" => base,
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
  defdelegate encode_secret(secret), to: OAuthSecret, as: :encode

  @doc "Decode a stored Kimi Code OAuth payload."
  @spec decode_secret(term()) :: {:ok, oauth_secret()} | :not_oauth
  def decode_secret(value), do: OAuthSecret.decode(value, [@secret_type])

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

  Stored refreshes use revision-aware `:reload_secret` and arity-three
  `:persist_secret` callbacks through `OAuthFlow`. A stale write returns
  `{:error, :oauth_secret_changed}` without exposing the refreshed token.
  """
  @spec resolve_api_key_from_secret(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  def resolve_api_key_from_secret(secret_name, secret_value, opts \\ []) do
    OAuthSecret.resolve(__MODULE__, secret_name, secret_value, opts, %{
      refresh: &refresh_secret(&1, opts),
      skew_ms: @refresh_skew_ms
    })
  end

  @doc """
  Whether a credential is a Kimi OAuth access token (a JWT) rather than a
  Kimi API key (`sk-…`).
  """
  @spec oauth_token?(term()) :: boolean()
  def oauth_token?(token) when is_binary(token) do
    not String.starts_with?(token, "sk-") and OAuthFlow.jwt_claims(token) != nil
  end

  def oauth_token?(_), do: false

  @doc """
  Kimi Code deployment endpoints for a region: `"china"` (kimi.com, the
  default) or `"global"` (kimi.ai). Accounts and tokens are scoped to the
  deployment that issued them, as in omp's `kimi-code`/`kimi-code-global`
  providers. Returns `:error` for an unknown region.
  """
  @spec region(String.t() | nil) ::
          {:ok, %{auth_base_url: String.t(), api_base_url: String.t(), omp_provider: String.t()}}
          | :error
  def region(name) when is_binary(name) do
    Map.fetch(@regions, name |> String.trim() |> String.downcase())
  end

  def region(_), do: :error

  @doc "Region names accepted by `region/1`."
  @spec regions() :: [String.t()]
  def regions, do: Map.keys(@regions) |> Enum.sort()

  @doc """
  The region a Kimi Code API base URL belongs to: `"global"` for a `kimi.ai`
  host, else `"china"` (including unset and non-Kimi hosts).
  """
  @spec region_for_base_url(String.t() | nil) :: String.t()
  def region_for_base_url(base_url) when is_binary(base_url) do
    case URI.parse(String.trim(base_url)).host do
      host when is_binary(host) ->
        if host == "kimi.ai" or String.ends_with?(host, ".kimi.ai"), do: "global", else: "china"

      _ ->
        "china"
    end
  end

  def region_for_base_url(_), do: "china"

  @doc "omp's provider id for the Kimi Code deployment serving `base_url`."
  @spec omp_provider(String.t() | nil) :: String.t()
  def omp_provider(base_url) do
    {:ok, %{omp_provider: provider}} = base_url |> region_for_base_url() |> region()
    provider
  end

  @doc "Kimi CLI fingerprint headers (lower-case names), cached for the auth cache owner's lifetime."
  @spec request_headers() :: [{String.t(), String.t()}]
  def request_headers do
    key = {__MODULE__, :request_headers}

    case Cache.get(key) do
      nil ->
        headers = build_request_headers()
        Cache.put(key, headers)
        headers

      headers ->
        headers
    end
  end

  @doc """
  The device id sent as `x-msh-device-id`.

  Read from `<home>/.lemon/kimi-device-id`. When the file is missing or empty
  it is seeded with the id Lemon derived from host name and home directory
  before the id was persisted, so existing logins keep the identity they were
  minted under and later host renames no longer change it. If the file cannot
  be read or written, the derived id is used for this VM. Never raises.

  Options: `:home` (defaults to `$HOME`), `:hostname`.
  """
  @spec device_id(keyword()) :: String.t()
  def device_id(opts \\ []) do
    home = Keyword.get_lazy(opts, :home, &home_dir/0)
    derived = derived_device_id(Keyword.get_lazy(opts, :hostname, &hostname/0), home)

    if is_binary(home) and home != "" do
      path = Path.join([home, ".lemon", @device_id_file])

      case File.read(path) do
        {:ok, content} ->
          case sanitize_device_id(content) do
            nil -> seed_device_id(path, derived)
            stored -> stored
          end

        {:error, :enoent} ->
          seed_device_id(path, derived)

        {:error, _} ->
          derived
      end
    else
      derived
    end
  rescue
    _ -> derived_device_id(hostname(), home_dir())
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
             refresh_base_url(secret, opts) <> "/api/oauth/token",
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

  defp login_base_url(opts) do
    with {:ok, name} when not is_nil(name) <- Keyword.fetch(opts, :region),
         nil <- Keyword.get(opts, :base_url) do
      case region(name) do
        {:ok, %{auth_base_url: url}} -> {:ok, url}
        :error -> {:error, :unknown_kimi_region}
      end
    else
      _ -> {:ok, base_url(opts)}
    end
  end

  # A token refreshes against the host that issued it; payloads saved before
  # `auth_base_url` was recorded use the configured host.
  defp refresh_base_url(secret, opts) do
    case {Keyword.get(opts, :base_url), OAuthFlow.non_empty_binary(secret["auth_base_url"])} do
      {nil, stored} when is_binary(stored) -> String.trim_trailing(stored, "/")
      _ -> base_url(opts)
    end
  end

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
    [
      {"user-agent", "KimiCLI/#{@kimi_cli_version}"},
      {"x-msh-platform", "kimi_cli"},
      {"x-msh-version", @kimi_cli_version},
      {"x-msh-device-name", sanitize(hostname())},
      {"x-msh-device-model", sanitize(device_model())},
      {"x-msh-os-version", sanitize(os_version())},
      {"x-msh-device-id", device_id()}
    ]
  end

  defp hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
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
      other -> to_string(other)
    end
  end

  # The pre-persistence identity; seeds the device-id file once.
  defp derived_device_id(hostname, home) do
    :crypto.hash(:sha256, "lemon-kimi-device:#{hostname}:#{home || ""}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp home_dir do
    OAuthFlow.non_empty_binary(System.get_env("HOME")) || System.user_home()
  end

  defp sanitize_device_id(content) do
    case content |> String.replace(~r/[^\x20-\x7E]/, "") |> String.trim() do
      "" -> nil
      id -> id
    end
  end

  # Create a private temporary file, then rename it into place so a concurrent
  # reader never sees a partial id; racing writers all store the derived value.
  defp seed_device_id(path, derived) do
    tmp = "#{path}.#{System.pid()}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, "", [:exclusive]),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.write(tmp, derived <> "\n"),
         :ok <- File.rename(tmp, path) do
      derived
    else
      _ ->
        _ = File.rm(tmp)
        derived
    end
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
