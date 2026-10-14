defmodule LemonAi.Auth.OAuthFlow do
  @moduledoc """
  Shared machinery for OAuth helpers that store a refreshable secret payload.

  - `request/3` performs one token-endpoint style HTTP call with retries
    disabled, a bounded timeout and caller `:req_options` merged in.
  - `poll_device_token/2` runs RFC 8628 device-code polling: it honors the
    provider interval, adds five seconds per `slow_down`, and stops at the
    device-code expiry. `:sleep` (default `Process.sleep/1`) is injectable.
  - `ensure_fresh/4` returns a usable secret map, refreshing it under a
    per-secret lock. A queued caller re-reads the stored secret through
    `:reload_secret` so it reuses the token the previous holder stored instead
    of replaying a rotated refresh token. A refreshed secret that
    `:persist_secret` fails to store is an error. `force_refresh: true`
    refreshes an unexpired token the provider rejected, unless the stored
    token already differs from it, and never falls back to the rejected token.
  """

  require Logger

  @default_interval_s 5
  @min_interval_ms 1_000
  # RFC 8628 servers normally send expires_in; bound polling when they do not.
  @default_expires_in_s 900
  @slow_down_increment_ms 5_000
  @request_timeout_ms 30_000

  @type response :: %{status: non_neg_integer(), body: map() | String.t()}
  @type poll_result :: {:ok, map()} | :pending | :slow_down | {:error, term()}

  @type refresh_spec :: %{
          required(:lock) => term(),
          required(:decode) => (String.t() -> {:ok, map()} | :not_oauth),
          required(:encode) => (map() -> String.t()),
          required(:refresh) => (map() -> {:ok, map()} | {:error, term()}),
          required(:skew_ms) => non_neg_integer()
        }

  # ── HTTP ───────────────────────────────────────────────────────────────────

  @doc """
  Perform one HTTP request. `opts` takes `:method` (default `:post`), `:form`,
  `:json`, `:headers` and `:req_options`. JSON bodies are decoded to maps.
  Transport failures return `{:error, {:transport_error, reason}}` without
  request details.
  """
  @spec request(String.t(), keyword(), keyword()) :: {:ok, response()} | {:error, term()}
  def request(url, request_opts, opts \\ []) do
    method = Keyword.get(request_opts, :method, :post)

    req_opts =
      [
        method: method,
        url: url,
        headers: Keyword.get(request_opts, :headers, []),
        retry: false,
        receive_timeout: @request_timeout_ms
      ]
      |> put_body(request_opts)
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, %{status: status, body: decode_body(body)}}

      {:error, exception} ->
        {:error, {:transport_error, transport_reason(exception)}}
    end
  end

  defp put_body(req_opts, request_opts) do
    cond do
      form = Keyword.get(request_opts, :form) -> Keyword.put(req_opts, :form, compact(form))
      json = Keyword.get(request_opts, :json) -> Keyword.put(req_opts, :json, compact(json))
      true -> req_opts
    end
  end

  defp compact(params) when is_map(params) do
    params |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
  end

  defp compact(params), do: params

  defp decode_body(body) when is_map(body), do: body

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> body
    end
  end

  defp decode_body(_body), do: ""

  defp transport_reason(%{reason: reason}) when is_atom(reason), do: reason
  defp transport_reason(_), do: :unknown

  @doc """
  Parse an OAuth token response. A response without a refresh token keeps
  `previous_refresh_token` (non-rotating grants).
  """
  @spec parse_token_response(map() | String.t(), String.t() | nil) ::
          {:ok,
           %{access_token: String.t(), refresh_token: String.t() | nil, expires_at_ms: integer()}}
          | {:error, term()}
  def parse_token_response(body, previous_refresh_token \\ nil)

  def parse_token_response(body, previous_refresh_token) when is_map(body) do
    access_token = non_empty_binary(body["access_token"])
    expires_in = parse_integer(body["expires_in"])

    cond do
      is_nil(access_token) ->
        {:error, :missing_access_token}

      not is_integer(expires_in) or expires_in <= 0 ->
        {:error, :invalid_expiry}

      true ->
        {:ok,
         %{
           access_token: access_token,
           refresh_token: non_empty_binary(body["refresh_token"]) || previous_refresh_token,
           expires_at_ms: System.system_time(:millisecond) + expires_in * 1000
         }}
    end
  end

  def parse_token_response(_body, _previous), do: {:error, :invalid_token_response}

  @doc """
  Map a refresh-grant response: `invalid_grant` means the login is gone
  (`{:error, :reauth_required}`); other failures keep their status and
  OAuth error code only.
  """
  @spec refresh_response(response(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def refresh_response(%{status: status, body: body}, previous_refresh_token)
      when status in 200..299 do
    parse_token_response(body, previous_refresh_token)
  end

  def refresh_response(%{status: status, body: %{"error" => "invalid_grant"}}, _)
      when status in [400, 401],
      do: {:error, :reauth_required}

  def refresh_response(%{status: status, body: body}, _), do: {:error, http_error(status, body)}

  @doc "Credential-free error term for a failed HTTP response."
  @spec http_error(non_neg_integer(), term()) :: tuple()
  def http_error(status, %{"error" => code}) when is_binary(code),
    do: {:http_error, status, code}

  def http_error(status, _body), do: {:http_error, status}

  # ── Device code ────────────────────────────────────────────────────────────

  @doc """
  Parse a standard device authorization response.
  """
  @spec parse_device_response(response()) :: {:ok, map()} | {:error, term()}
  def parse_device_response(%{status: status, body: body}) when status in 200..299 do
    device_code = non_empty_binary(body["device_code"])
    user_code = non_empty_binary(body["user_code"])
    verification_uri = non_empty_binary(body["verification_uri"])

    if device_code && user_code && verification_uri do
      {:ok,
       %{
         device_code: device_code,
         user_code: user_code,
         verification_uri: verification_uri,
         verification_uri_complete: non_empty_binary(body["verification_uri_complete"]),
         interval: parse_integer(body["interval"]),
         expires_in: parse_integer(body["expires_in"])
       }}
    else
      {:error, :invalid_device_authorization_response}
    end
  end

  def parse_device_response(%{status: status, body: body}),
    do: {:error, {:device_authorization_failed, http_error(status, body)}}

  def parse_device_response(_), do: {:error, :invalid_device_authorization_response}

  @doc """
  Classify one RFC 8628 token poll response.
  """
  @spec classify_device_token_response(response()) :: poll_result()
  def classify_device_token_response(%{status: status, body: body}) do
    error = if is_map(body), do: body["error"]

    cond do
      status in 200..299 and is_nil(error) and is_map(body) -> {:ok, body}
      error == "authorization_pending" -> :pending
      error == "slow_down" -> :slow_down
      error == "expired_token" -> {:error, :device_code_expired}
      error == "access_denied" -> {:error, :access_denied}
      true -> {:error, {:device_token_failed, http_error(status, body)}}
    end
  end

  @doc """
  Poll `poll_fun` until it completes, fails, or the device code expires.

  Options: `:interval_s` and `:expires_in_s` from the device response, and
  `:sleep` (a 1-arity function receiving milliseconds). Expiry counts the time
  spent waiting between polls; a code that expires during a request is
  reported by the server as `expired_token`.
  """
  @spec poll_device_token((-> poll_result()), keyword()) :: {:ok, map()} | {:error, term()}
  def poll_device_token(poll_fun, opts) when is_function(poll_fun, 0) do
    interval_s = positive(Keyword.get(opts, :interval_s)) || @default_interval_s
    expires_in_s = positive(Keyword.get(opts, :expires_in_s)) || @default_expires_in_s
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)

    do_poll(poll_fun, max(@min_interval_ms, interval_s * 1000), expires_in_s * 1000, sleep, false)
  end

  defp do_poll(poll_fun, interval_ms, remaining_ms, sleep, slowed?) do
    case poll_fun.() do
      {:ok, _body} = done ->
        done

      {:error, _reason} = error ->
        error

      result when result in [:pending, :slow_down] ->
        {interval_ms, slowed?} =
          if result == :slow_down,
            do: {interval_ms + @slow_down_increment_ms, true},
            else: {interval_ms, slowed?}

        if remaining_ms <= interval_ms do
          {:error, timeout_reason(slowed?)}
        else
          sleep.(interval_ms)
          do_poll(poll_fun, interval_ms, remaining_ms - interval_ms, sleep, slowed?)
        end
    end
  end

  # Repeated slow_down responses usually mean clock drift (VMs, WSL).
  defp timeout_reason(true), do: :device_flow_timed_out_after_slow_down
  defp timeout_reason(false), do: :device_flow_timed_out

  # ── Refresh ────────────────────────────────────────────────────────────────

  @doc """
  Return a usable secret map for `secret`, refreshing it when it is within
  `spec.skew_ms` of expiry or when `opts[:force_refresh]` is true. See the
  module documentation for locking, persistence and fallback rules.
  """
  @spec ensure_fresh(String.t(), map(), keyword(), refresh_spec()) ::
          {:ok, map()} | {:error, term()}
  def ensure_fresh(secret_name, secret, opts, spec) do
    force? = Keyword.get(opts, :force_refresh, false) == true

    if force? or refresh_due?(secret, spec.skew_ms) do
      :global.trans(
        {{spec.lock, :refresh, secret_name}, self()},
        fn ->
          with {:ok, latest} <- reload(secret_name, secret, opts, spec) do
            cond do
              force? and latest["access_token"] == secret["access_token"] ->
                refresh_and_persist(secret_name, latest, true, opts, spec)

              not force? and refresh_due?(latest, spec.skew_ms) ->
                refresh_and_persist(secret_name, latest, false, opts, spec)

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

  defp refresh_due?(secret, skew_ms) do
    expires_at_ms = parse_integer(secret["expires_at_ms"])

    cond do
      is_nil(non_empty_binary(secret["refresh_token"])) -> false
      is_nil(non_empty_binary(secret["access_token"])) -> true
      is_nil(expires_at_ms) -> false
      true -> expires_at_ms - System.system_time(:millisecond) <= skew_ms
    end
  end

  defp usable(secret) do
    cond do
      is_nil(non_empty_binary(secret["access_token"])) -> {:error, :missing_access_token}
      expired?(secret) -> {:error, :expired_access_token}
      true -> {:ok, secret}
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

  # Without a reload callback the caller's copy is the latest one available. A
  # deleted or replaced login must not be refreshed from a stale copy.
  defp reload(secret_name, stale, opts, spec) do
    case Keyword.get(opts, :reload_secret) do
      reload when is_function(reload, 1) ->
        with {:ok, value} when is_binary(value) <- reload.(secret_name),
             {:ok, secret} <- spec.decode.(value) do
          {:ok, secret}
        else
          :not_oauth -> {:error, :oauth_secret_replaced}
          _ -> {:error, :oauth_secret_missing}
        end

      _ ->
        {:ok, stale}
    end
  end

  defp refresh_and_persist(secret_name, secret, force?, opts, spec) do
    if is_nil(non_empty_binary(secret["refresh_token"])) do
      {:error, :not_refreshable}
    else
      case spec.refresh.(secret) do
        {:ok, refreshed} ->
          with :ok <- persist(secret_name, refreshed, opts, spec), do: {:ok, refreshed}

        {:error, :reauth_required} = error ->
          error

        {:error, reason} ->
          if not force? and non_empty_binary(secret["access_token"]) != nil and
               not expired?(secret) do
            Logger.debug("OAuth refresh failed; using the unexpired access token")
            {:ok, secret}
          else
            {:error, reason}
          end
      end
    end
  end

  # A refreshed secret that was not stored is a failure: the previous refresh
  # token may already be revoked.
  defp persist(secret_name, secret, opts, spec) do
    case Keyword.get(opts, :persist_secret) do
      callback when is_function(callback, 2) ->
        case callback.(secret_name, spec.encode.(secret)) do
          {:error, _} -> {:error, :oauth_secret_persistence_failed}
          _ -> :ok
        end

      _ ->
        :ok
    end
  rescue
    _ -> {:error, :oauth_secret_persistence_failed}
  end

  # ── Callbacks and helpers ──────────────────────────────────────────────────

  @doc "Invoke `:on_auth` with the URL and instructions; required for interactive flows."
  @spec notify_auth(keyword(), String.t(), String.t()) :: :ok | {:error, :auth_callback_required}
  def notify_auth(opts, url, instructions) do
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

  @doc "Invoke `:on_progress` when present."
  @spec notify_progress(keyword(), String.t()) :: :ok
  def notify_progress(opts, message) do
    case Keyword.get(opts, :on_progress) do
      callback when is_function(callback, 1) -> callback.(message)
      _ -> :ok
    end

    :ok
  end

  @doc "Decode a JWT payload without verifying it; `nil` when malformed."
  @spec jwt_claims(term()) :: map() | nil
  def jwt_claims(token) when is_binary(token) do
    with [_header, payload, _signature] <- String.split(token, ".", parts: 3),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} when is_map(claims) <- Jason.decode(decoded) do
      claims
    else
      _ -> nil
    end
  end

  def jwt_claims(_), do: nil

  @doc "First non-empty string claim among `names`."
  @spec claim(map() | nil, [String.t()]) :: String.t() | nil
  def claim(nil, _names), do: nil

  def claim(claims, names) do
    Enum.find_value(names, fn name ->
      case claims[name] do
        value when is_binary(value) -> non_empty_binary(value)
        value when is_integer(value) -> Integer.to_string(value)
        _ -> nil
      end
    end)
  end

  @spec non_empty_binary(term()) :: String.t() | nil
  def non_empty_binary(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def non_empty_binary(_), do: nil

  @spec parse_integer(term()) :: integer() | nil
  def parse_integer(value) when is_integer(value), do: value
  def parse_integer(value) when is_float(value), do: trunc(value)

  def parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  def parse_integer(_), do: nil

  @spec normalize_prompt_input(term()) :: String.t()
  def normalize_prompt_input(value) when is_binary(value), do: String.trim(value)
  def normalize_prompt_input(value) when is_list(value), do: value |> to_string() |> String.trim()
  def normalize_prompt_input(_), do: ""

  defp positive(value) do
    case parse_integer(value) do
      int when is_integer(int) and int > 0 -> int
      _ -> nil
    end
  end
end
