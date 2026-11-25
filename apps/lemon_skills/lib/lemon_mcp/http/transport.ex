defmodule LemonMCP.HTTP.Transport do
  @moduledoc false

  # One HTTP exchange for the Streamable HTTP client and its OAuth discovery.
  #
  # `conn` carries `:origin_policy`, `:peer_owner` and `:timeout_ms`. A pinned
  # request goes through `LemonCore.Net.HTTP` (one deadline per hop). Operator
  # networking without an origin policy keeps the default httpc profile
  # (proxies, OS resolution); httpc bounds connect and response separately, so
  # the exchange runs in a linked worker killed at the same single deadline.
  # Redirects are never followed.

  alias LemonMCP.HTTP.OriginPolicy

  @spec ensure_started() :: :ok | {:error, term()}
  def ensure_started do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl) do
      :ok
    end
  end

  @spec request(atom(), String.t(), list(), nil | {charlist(), iodata()}, map(), map() | nil) ::
          {:ok, {{charlist(), integer(), charlist()}, list(), binary()}} | {:error, term()}
  def request(method, url, headers, body, conn, pin) do
    timeout = conn.timeout_ms

    response =
      case pin do
        nil -> legacy_request(method, url, headers, body, timeout)
        pin -> pinned_request(method, url, headers, body, timeout, pin, conn)
      end

    case response do
      {:ok, {{_version, status, _reason}, _headers, _body}} when status in 300..399 ->
        {:error, :redirect_forbidden}

      {:error, :private_origin_not_owned} = error ->
        error

      {:error, reason} ->
        if is_nil(conn.origin_policy),
          do: {:error, {:http_request_failed, reason}},
          else: {:error, :http_request_failed}

      response ->
        response
    end
  end

  @spec headers([{term(), term()}]) :: [{charlist(), charlist()}]
  def headers(headers) do
    Enum.map(headers, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)
  end

  @spec response_header(list(), String.t()) :: String.t() | nil
  def response_header(headers, name) do
    needle = String.downcase(name)

    Enum.find_value(headers, fn
      {key, value} ->
        if key |> to_string() |> String.downcase() == needle do
          to_string(value)
        end

      _ ->
        nil
    end)
  end

  # httpc queues a request behind an outstanding one on a keep-alive session;
  # `connection: close` gives every exchange its own connection so one slow
  # request never delays another.
  defp legacy_request(method, url, headers, body, timeout) do
    headers = [{~c"connection", ~c"close"} | headers]

    request =
      case body do
        nil -> {to_charlist(url), headers}
        {content_type, data} -> {to_charlist(url), headers, content_type, data}
      end

    worker =
      Task.async(fn ->
        :httpc.request(
          method,
          request,
          [timeout: timeout, connect_timeout: timeout, autoredirect: false],
          body_format: :binary
        )
      end)

    case Task.yield(worker, timeout) || Task.shutdown(worker, :brutal_kill) do
      {:ok, response} -> response
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  # The pin is the authorized destination: the request goes to its address on
  # one unpooled connection while Host/TLS identity stay the pin's host.
  defp pinned_request(method, url, headers, body, timeout, pin, conn) do
    uri = URI.parse(url)
    url = URI.to_string(%{uri | scheme: pin.scheme, host: pin.host, port: pin.port})

    headers =
      Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
      |> Enum.reject(fn {key, _} -> String.downcase(key) in ["host", "connection"] end)

    # The body's type is authoritative, as with :httpc. A second content-type
    # header joins into "application/json, application/json", which strict
    # servers (Lemon Bot among them) reject as unsupported media.
    {headers, data} =
      case body do
        nil ->
          {headers, nil}

        {type, data} ->
          headers =
            Enum.reject(headers, fn {key, _} -> String.downcase(key) == "content-type" end)

          {[{"content-type", to_string(type)} | headers], data}
      end

    peer_check = if OriginPolicy.ownership_required?(pin), do: conn.peer_owner

    case LemonCore.Net.HTTP.request(method, url,
           address: pin.address,
           headers: headers,
           body: data,
           timeout_ms: timeout,
           peer_check: peer_check
         ) do
      {:ok, %{status: status, headers: resp_headers, body: resp_body}} ->
        resp_headers =
          Enum.map(resp_headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

        {:ok, {{~c"HTTP/1.1", status, ~c""}, resp_headers, resp_body}}

      {:error, _} = error ->
        error
    end
  end
end
