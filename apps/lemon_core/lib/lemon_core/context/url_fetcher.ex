defmodule LemonCore.Context.URLFetcher do
  @moduledoc """
  Bounded public-HTTP fetches for context references.

  Every hop is parsed and DNS-resolved before use. Requests connect to a
  validated IP while retaining the original Host header and TLS SNI name, so a
  later DNS rebind cannot redirect the socket to a private address. Redirects
  are followed manually and re-enter the same checks.
  """

  import Bitwise

  alias LemonCore.Httpc

  @default_max_bytes 8_000_000
  @default_timeout_ms 10_000
  @default_redirects 3
  @blocked_names MapSet.new(["localhost", "localhost.localdomain", "metadata.google.internal"])

  @spec fetch(String.t(), keyword()) :: {:ok, binary(), map()} | {:error, term()}
  def fetch(url, opts \\ []) when is_binary(url) do
    do_fetch(String.trim(url), opts, 0, MapSet.new())
  end

  defp do_fetch(url, opts, redirect_count, visited) do
    max_redirects = positive(opts[:max_redirects], @default_redirects)

    with {:ok, uri} <- parse_uri(url),
         :ok <- reject_credentials(uri),
         {:ok, addresses} <- resolve_public(uri.host, opts),
         {:ok, response} <- request(uri, hd(addresses), opts) do
      case response do
        %{status: status, headers: headers} when status in [301, 302, 303, 307, 308] ->
          with :ok <- redirect_allowed(redirect_count, max_redirects),
               {:ok, location} <- header(headers, "location"),
               {:ok, next} <- redirect_url(uri, location),
               :ok <- reject_loop(next, visited) do
            do_fetch(next, opts, redirect_count + 1, MapSet.put(visited, next))
          end

        %{status: status, body: body, headers: headers} when status in 200..299 ->
          {:ok, body,
           %{
             final_url: redacted_url(uri),
             status: status,
             content_type: header_value(headers, "content-type"),
             redirects: redirect_count
           }}

        %{status: status} ->
          {:error, {:http_status, status}}
      end
    end
  end

  defp parse_uri(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, uri}

      _ ->
        {:error, :invalid_url}
    end
  end

  defp reject_credentials(%URI{userinfo: nil}), do: :ok
  defp reject_credentials(%URI{userinfo: ""}), do: :ok
  defp reject_credentials(_), do: {:error, :url_credentials_forbidden}

  defp resolve_public(host, opts) do
    normalized = host |> String.trim_trailing(".") |> String.downcase()

    cond do
      MapSet.member?(@blocked_names, normalized) ->
        {:error, :ssrf_blocked}

      String.ends_with?(normalized, ".localhost") or String.ends_with?(normalized, ".local") ->
        {:error, :ssrf_blocked}

      true ->
        resolver = Keyword.get(opts, :resolve_fun, &default_resolve/1)

        case resolver.(normalized) do
          {:ok, addresses} when is_list(addresses) and addresses != [] ->
            if Enum.all?(addresses, &public_ip?/1),
              do: {:ok, addresses},
              else: {:error, :ssrf_blocked}

          _ ->
            {:error, :dns_failed}
        end
    end
  end

  defp default_resolve(host) do
    hostname = String.to_charlist(host)

    v4 =
      case :inet.getaddrs(hostname, :inet) do
        {:ok, ips} -> ips
        _ -> []
      end

    v6 =
      case :inet.getaddrs(hostname, :inet6) do
        {:ok, ips} -> ips
        _ -> []
      end

    if v4 ++ v6 == [], do: {:error, :nxdomain}, else: {:ok, v4 ++ v6}
  end

  defp request(uri, address, opts) do
    request_fun = Keyword.get(opts, :request_fun, &httpc_request/4)
    max_bytes = positive(opts[:max_input_bytes], @default_max_bytes)
    timeout = positive(opts[:timeout_ms], @default_timeout_ms)
    host_header = host_header(uri)
    pinned_url = pinned_url(uri, address)

    case request_fun.(
           pinned_url,
           [{~c"host", String.to_charlist(host_header)}],
           http_options(uri, timeout),
           max_bytes
         ) do
      {:ok, {{_version, status, _reason}, headers, body}} ->
        body = IO.iodata_to_binary(body)

        if byte_size(body) <= max_bytes do
          {:ok, %{status: status, headers: normalize_headers(headers), body: body}}
        else
          {:error, {:input_too_large, byte_size(body), max_bytes}}
        end

      {:error, reason} ->
        {:error, normalize_http_error(reason)}

      _ ->
        {:error, :network_error}
    end
  end

  defp httpc_request(url, headers, http_options, max_bytes) do
    Httpc.request(
      :get,
      {String.to_charlist(url), headers},
      Keyword.put(http_options, :max_body_length, max_bytes),
      body_format: :binary
    )
  end

  defp http_options(uri, timeout) do
    base = [timeout: timeout, connect_timeout: timeout, autoredirect: false]

    if uri.scheme == "https" do
      ssl = [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(uri.host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]

      Keyword.put(base, :ssl, ssl)
    else
      base
    end
  end

  defp pinned_url(uri, address) do
    host = address |> :inet.ntoa() |> List.to_string()
    host = if tuple_size(address) == 8, do: "[#{host}]", else: host
    port = uri.port || default_port(uri.scheme)
    port_suffix = if port == default_port(uri.scheme), do: "", else: ":#{port}"
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    query = if uri.query, do: "?#{uri.query}", else: ""
    "#{uri.scheme}://#{host}#{port_suffix}#{path}#{query}"
  end

  defp host_header(uri) do
    port = uri.port || default_port(uri.scheme)
    if port == default_port(uri.scheme), do: uri.host, else: "#{uri.host}:#{port}"
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443

  defp normalize_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {name |> to_string() |> String.downcase(), to_string(value)}
    end)
  end

  defp header(headers, name) do
    case header_value(headers, name) do
      nil -> {:error, :redirect_without_location}
      value -> {:ok, value}
    end
  end

  defp header_value(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: to_string(value)
    end)
  end

  defp redirect_url(uri, location) do
    try do
      value = uri |> URI.merge(location) |> URI.to_string()
      if value == "", do: {:error, :invalid_redirect}, else: {:ok, value}
    rescue
      _ -> {:error, :invalid_redirect}
    end
  end

  defp redirect_allowed(count, max) when count < max, do: :ok
  defp redirect_allowed(_, _), do: {:error, :redirect_limit}

  defp reject_loop(url, visited),
    do: if(MapSet.member?(visited, url), do: {:error, :redirect_loop}, else: :ok)

  defp redacted_url(%URI{} = uri),
    do: %URI{uri | userinfo: nil, query: nil, fragment: nil} |> URI.to_string()

  defp public_ip?({a, b, _c, _d}) do
    cond do
      a == 0 -> false
      a == 10 -> false
      a == 127 -> false
      a == 169 and b == 254 -> false
      a == 172 and b in 16..31 -> false
      a == 192 and b == 168 -> false
      a == 100 and b in 64..127 -> false
      a >= 224 -> false
      true -> true
    end
  end

  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false

  defp public_ip?({a, _b, _c, _d, _e, _f, _g, _h}) do
    cond do
      a == 0 -> false
      (a &&& 0xFE00) == 0xFC00 -> false
      (a &&& 0xFFC0) == 0xFE80 -> false
      (a &&& 0xFF00) == 0xFF00 -> false
      true -> true
    end
  end

  defp public_ip?(_), do: false

  defp normalize_http_error({:body_too_big, _}), do: :input_too_large
  defp normalize_http_error(:body_too_big), do: :input_too_large
  defp normalize_http_error(_), do: :network_error

  defp positive(value, _default) when is_integer(value) and value >= 0, do: value
  defp positive(_, default), do: default
end
