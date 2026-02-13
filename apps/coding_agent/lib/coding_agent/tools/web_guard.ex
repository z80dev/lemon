defmodule CodingAgent.Tools.WebGuard do
  @moduledoc false

  import Bitwise

  @type fetch_error ::
          {:invalid_url, String.t()}
          | {:ssrf_blocked, String.t()}
          | {:redirect_error, String.t()}
          | {:network_error, String.t()}

  @redirect_statuses [301, 302, 303, 307, 308]
  @blocked_hostnames MapSet.new(["localhost", "metadata.google.internal"])

  @spec guarded_get(String.t(), keyword()) ::
          {:ok, Req.Response.t(), String.t()} | {:error, fetch_error()}
  def guarded_get(url, opts \\ []) when is_binary(url) do
    max_redirects =
      opts
      |> Keyword.get(:max_redirects, 3)
      |> normalize_integer(3)
      |> max(0)

    do_guarded_get(url, opts, 0, max_redirects, MapSet.new())
  end

  @spec ssrf_blocked?({:error, fetch_error()} | fetch_error() | term()) :: boolean()
  def ssrf_blocked?({:error, reason}), do: ssrf_blocked?(reason)
  def ssrf_blocked?({:ssrf_blocked, _}), do: true
  def ssrf_blocked?(_), do: false

  defp do_guarded_get(url, opts, redirect_count, max_redirects, visited) do
    with {:ok, uri} <- parse_http_uri(url),
         :ok <- assert_safe_hostname(uri.host, opts),
         {:ok, response} <- http_get(url, opts) do
      if response.status in @redirect_statuses do
        follow_redirect(url, uri, response, opts, redirect_count, max_redirects, visited)
      else
        {:ok, response, url}
      end
    end
  end

  defp follow_redirect(_url, uri, response, opts, redirect_count, max_redirects, visited) do
    if redirect_count >= max_redirects do
      {:error, {:redirect_error, "Too many redirects (limit: #{max_redirects})"}}
    else
      case header_value(response.headers, "location") do
        nil ->
          {:error, {:redirect_error, "Redirect missing location header (#{response.status})"}}

        location ->
          with {:ok, next_url} <- build_redirect_url(uri, location),
               :ok <- detect_redirect_loop(next_url, visited) do
            do_guarded_get(
              next_url,
              opts,
              redirect_count + 1,
              max_redirects,
              MapSet.put(visited, next_url)
            )
          end
      end
    end
  end

  defp parse_http_uri(url) when is_binary(url) do
    trimmed = String.trim(url)

    case URI.parse(trimmed) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, uri}

      _ ->
        {:error, {:invalid_url, "Invalid URL: must be http or https"}}
    end
  end

  defp build_redirect_url(base_uri, location) when is_binary(location) do
    try do
      next = URI.merge(base_uri, location)

      case to_string(next) do
        "" -> {:error, {:redirect_error, "Invalid redirect location"}}
        url -> {:ok, url}
      end
    rescue
      _ -> {:error, {:redirect_error, "Invalid redirect location"}}
    end
  end

  defp detect_redirect_loop(next_url, visited) do
    if MapSet.member?(visited, next_url) do
      {:error, {:redirect_error, "Redirect loop detected"}}
    else
      :ok
    end
  end

  defp http_get(url, opts) do
    timeout_ms = opts |> Keyword.get(:timeout_ms, 30_000) |> normalize_integer(30_000)
    headers = Keyword.get(opts, :headers, [])
    custom = Keyword.get(opts, :http_get)

    request_opts = [
      headers: headers,
      decode_body: false,
      redirect: false,
      connect_options: [timeout: timeout_ms],
      receive_timeout: timeout_ms
    ]

    result =
      cond do
        is_function(custom, 2) ->
          custom.(url, request_opts)

        true ->
          Req.get(url, request_opts)
      end

    case result do
      {:ok, %Req.Response{} = response} ->
        {:ok, response}

      %Req.Response{} = response ->
        {:ok, response}

      {:error, reason} ->
        {:error, {:network_error, format_reason(reason)}}

      other ->
        {:error, {:network_error, "Unexpected HTTP result: #{inspect(other)}"}}
    end
  end

  defp assert_safe_hostname(hostname, opts) do
    normalized_host = normalize_hostname(hostname)
    allow_private_network = Keyword.get(opts, :allow_private_network, false)
    allowed_hosts = normalize_allowed_hosts(Keyword.get(opts, :allowed_hostnames, []))
    explicitly_allowed = MapSet.member?(allowed_hosts, normalized_host)

    cond do
      normalized_host == "" ->
        {:error, {:invalid_url, "Invalid hostname"}}

      allow_private_network or explicitly_allowed ->
        :ok

      blocked_hostname?(normalized_host) ->
        {:error, {:ssrf_blocked, "Blocked hostname: #{normalized_host}"}}

      true ->
        with {:ok, addresses} <- resolve_host_addresses(normalized_host),
             :ok <- assert_public_addresses(addresses) do
          :ok
        end
    end
  end

  defp resolve_host_addresses(hostname) do
    case parse_ip_literal(hostname) do
      {:ok, ip} ->
        {:ok, [ip]}

      :error ->
        v4 =
          try do
            :inet_res.lookup(String.to_charlist(hostname), :in, :a)
          rescue
            _ -> []
          end

        v6 =
          try do
            :inet_res.lookup(String.to_charlist(hostname), :in, :aaaa)
          rescue
            _ -> []
          end

        addresses = Enum.uniq(v4 ++ v6)

        if addresses == [] do
          {:error, {:network_error, "Unable to resolve hostname: #{hostname}"}}
        else
          {:ok, addresses}
        end
    end
  end

  defp assert_public_addresses(addresses) when is_list(addresses) do
    if Enum.any?(addresses, &private_ip?/1) do
      {:error, {:ssrf_blocked, "Blocked: resolves to private/internal IP address"}}
    else
      :ok
    end
  end

  defp parse_ip_literal(hostname) do
    case :inet.parse_address(String.to_charlist(hostname)) do
      {:ok, ip} ->
        {:ok, ip}

      _ ->
        case parse_nonstandard_ipv4(hostname) do
          nil -> :error
          ip -> {:ok, ip}
        end
    end
  end

  defp parse_nonstandard_ipv4(hostname) do
    components = String.split(hostname, ".", trim: true)

    if components == [] or length(components) > 4 do
      nil
    else
      with true <- Enum.all?(components, &valid_ipv4_component?/1),
           parsed when not is_nil(parsed) <- Enum.map(components, &parse_ipv4_component/1),
           ip when not is_nil(ip) <- build_ipv4(parsed) do
        ip
      else
        _ -> nil
      end
    end
  end

  defp valid_ipv4_component?(component) do
    Regex.match?(~r/^(0x[0-9a-fA-F]+|0[0-7]*|[0-9]+)$/, component)
  end

  defp parse_ipv4_component("0x" <> value), do: parse_integer(value, 16)
  defp parse_ipv4_component("0X" <> value), do: parse_integer(value, 16)

  defp parse_ipv4_component(value) do
    cond do
      String.length(value) > 1 and String.starts_with?(value, "0") ->
        parse_integer(value, 8)

      true ->
        parse_integer(value, 10)
    end
  end

  defp parse_integer(value, base) do
    case Integer.parse(value, base) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp build_ipv4([a]) when a >= 0 and a <= 0xFFFFFFFF, do: int_to_ipv4(a)

  defp build_ipv4([a, b]) when a <= 255 and b <= 0xFFFFFF do
    int_to_ipv4((a <<< 24) + b)
  end

  defp build_ipv4([a, b, c]) when a <= 255 and b <= 255 and c <= 0xFFFF do
    int_to_ipv4((a <<< 24) + (b <<< 16) + c)
  end

  defp build_ipv4([a, b, c, d]) when a <= 255 and b <= 255 and c <= 255 and d <= 255 do
    {a, b, c, d}
  end

  defp build_ipv4(_), do: nil

  defp int_to_ipv4(value) do
    {
      value >>> 24 &&& 0xFF,
      value >>> 16 &&& 0xFF,
      value >>> 8 &&& 0xFF,
      value &&& 0xFF
    }
  end

  defp private_ip?({a, b, _c, _d}) do
    cond do
      a == 0 -> true
      a == 10 -> true
      a == 127 -> true
      a == 169 and b == 254 -> true
      a == 172 and b >= 16 and b <= 31 -> true
      a == 192 and b == 168 -> true
      a == 100 and b >= 64 and b <= 127 -> true
      true -> false
    end
  end

  defp private_ip?(ip) when tuple_size(ip) == 8 do
    cond do
      ip == {0, 0, 0, 0, 0, 0, 0, 0} ->
        true

      ip == {0, 0, 0, 0, 0, 0, 0, 1} ->
        true

      mapped_ipv4 = mapped_ipv4(ip) ->
        private_ip?(mapped_ipv4)

      true ->
        first = elem(ip, 0)

        (first &&& 0xFFC0) == 0xFE80 or
          (first &&& 0xFFC0) == 0xFEC0 or
          (first &&& 0xFE00) == 0xFC00
    end
  end

  defp private_ip?(_), do: false

  defp mapped_ipv4({0, 0, 0, 0, 0, 65_535, hi, lo}) do
    {
      hi >>> 8 &&& 0xFF,
      hi &&& 0xFF,
      lo >>> 8 &&& 0xFF,
      lo &&& 0xFF
    }
  end

  defp mapped_ipv4(_), do: nil

  defp blocked_hostname?(hostname) do
    MapSet.member?(@blocked_hostnames, hostname) or
      String.ends_with?(hostname, ".localhost") or
      String.ends_with?(hostname, ".local") or
      String.ends_with?(hostname, ".internal")
  end

  defp normalize_allowed_hosts(list) when is_list(list) do
    list
    |> Enum.map(&normalize_hostname/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalize_allowed_hosts(_), do: MapSet.new()

  defp normalize_hostname(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.trim_trailing(".")
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
  end

  defp normalize_hostname(_), do: ""

  defp header_value(headers, key) do
    Enum.find_value(headers, fn {header_key, header_value} ->
      if String.downcase(to_string(header_key)) == String.downcase(key),
        do: to_string(header_value)
    end)
  end

  defp normalize_integer(value, _default) when is_integer(value), do: value

  defp normalize_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp normalize_integer(_value, default), do: default

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)
end
