defmodule LemonMCP.HTTP.OriginPolicy do
  @moduledoc """
  Destination-local origin authorization and DNS pinning for HTTP MCP clients.

  A policy contains `:allowed_origins` and optional `:approved_private_origins`
  lists of canonical origin strings. JSON `allowedOrigins` and
  `approvedPrivateOrigins` keys are also accepted. Origins are exact: scheme,
  IDNA ASCII hostname and effective port must match. Default ports are omitted,
  DNS names are lowercased and a final DNS root dot is removed. Unicode URL
  hostnames use non-transitional UTS #46 with STD3 rules; policy strings must
  already be canonical. Credentials, fragments and scoped IPv6 are rejected.
  Both lists must be unique, and approved origins must also be allowed. Pins
  retain the original URL, but `host` is the canonical ASCII DNS/IP hostname.

  Every A and AAAA answer must be public unless that exact allowed origin is
  explicitly approved for private networking. The selected address is stable
  regardless of DNS answer order. The transport must use this address without
  resolving again, preserve the origin's Host/TLS identity and disable redirects.
  A pin is internal process data, never authority accepted from a server config.

  `nil` policy returns `{:ok, nil}` without changing legacy operator networking.
  Errors contain only classified atoms, never URLs, hosts or resolver reasons.
  """

  @max_url_bytes 8_192
  @max_host_bytes 1_024
  @max_origin_bytes 512
  @max_policy_origins 128
  @max_addresses 64

  @type error ::
          :invalid_url
          | :invalid_origin_policy
          | :origin_not_allowed
          | :dns_resolution_failed
          | :invalid_dns_answer
          | :too_many_dns_addresses
          | :destination_not_public

  @type pin :: %{
          url: String.t(),
          origin: String.t(),
          scheme: String.t(),
          host: String.t(),
          port: pos_integer(),
          address: :inet.ip_address()
        }

  @doc """
  Authorizes a URL and resolves a destination pin on the executing host.

  The optional internal `:resolver` is a function receiving the canonical ASCII
  hostname and returning `{:ok, [ip_tuple]}` or `{:error, reason}`. Literal IPs
  bypass DNS, not address validation. Production resolves both address families;
  any resolver failure other than an absent record fails closed.
  """
  @spec pin(term(), map() | nil, keyword()) :: {:ok, pin() | nil} | {:error, error()}
  def pin(url, policy, opts \\ [])
  def pin(_url, nil, _opts), do: {:ok, nil}

  def pin(url, policy, opts) do
    with {:ok, destination} <- parse_destination(url),
         {:ok, allowed, approved} <- policy_origins(policy),
         :ok <- require_allowed(destination.origin, allowed),
         {:ok, addresses} <- resolve(destination.dns_host, opts),
         :ok <- validate_addresses(addresses, destination.origin in approved) do
      {:ok,
       %{
         url: url,
         origin: destination.origin,
         scheme: destination.scheme,
         host: destination.dns_host,
         port: destination.port,
         address: Enum.min(addresses)
       }}
    end
  end

  @doc "Returns the canonical HTTP(S) origin, rejecting unsafe URL syntax."
  @spec canonical_origin(term()) :: {:ok, String.t()} | {:error, :invalid_url}
  def canonical_origin(url) do
    with {:ok, destination} <- parse_destination(url), do: {:ok, destination.origin}
  end

  defp parse_destination(url)
       when is_binary(url) and byte_size(url) > 0 and byte_size(url) <= @max_url_bytes do
    with true <- String.valid?(url),
         false <- Regex.match?(~r/[\x00-\x20\x7f\\]/u, url),
         {:ok, uri} <- URI.new(url),
         scheme when scheme in ["http", "https"] <- normalize_scheme(uri.scheme),
         nil <- uri.userinfo,
         nil <- uri.fragment,
         host when is_binary(host) and byte_size(host) > 0 and
                     byte_size(host) <= @max_host_bytes <- uri.host,
         authority when is_binary(authority) <- uri.authority,
         true <- valid_authority?(authority),
         port when is_integer(port) and port in 1..65_535 <- uri.port || default_port(scheme),
         {:ok, dns_host} <- canonical_host(host) do
      origin_host = if String.contains?(dns_host, ":"), do: "[#{dns_host}]", else: dns_host
      suffix = if port == default_port(scheme), do: "", else: ":#{port}"

      {:ok,
       %{
         origin: "#{scheme}://#{origin_host}#{suffix}",
         scheme: scheme,
         dns_host: dns_host,
         port: port
       }}
    else
      _ -> {:error, :invalid_url}
    end
  rescue
    _ -> {:error, :invalid_url}
  catch
    _, _ -> {:error, :invalid_url}
  end

  defp parse_destination(_), do: {:error, :invalid_url}

  defp normalize_scheme(scheme) when is_binary(scheme), do: String.downcase(scheme)
  defp normalize_scheme(_), do: nil

  defp valid_authority?(authority) do
    not String.contains?(authority, ["@", "%"]) and
      Regex.match?(~r/\A(?:\[[0-9a-fA-F:.]+\]|[^:\[\]]+)(?::[0-9]{1,5})?\z/u, authority)
  end

  defp canonical_host(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} ->
        {:ok, address |> :inet.ntoa() |> List.to_string()}

      {:error, _} ->
        canonical_dns_host(host)
    end
  end

  defp canonical_dns_host(host) do
    ascii =
      host
      |> String.to_charlist()
      |> :idna.encode([:uts46, :std3_rules])
      |> List.to_string()
      |> String.downcase()

    ascii =
      if String.ends_with?(ascii, "."),
        do: binary_part(ascii, 0, byte_size(ascii) - 1),
        else: ascii

    labels = String.split(ascii, ".")

    if byte_size(ascii) in 1..253 and
         Enum.all?(labels, fn label ->
           byte_size(label) in 1..63 and
             Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, label)
         end) do
      {:ok, ascii}
    else
      {:error, :invalid_url}
    end
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443

  defp policy_origins(policy) when is_map(policy) do
    with {:ok, allowed} <- policy_field(policy, :allowed_origins, "allowedOrigins", :required),
         {:ok, approved} <-
           policy_field(policy, :approved_private_origins, "approvedPrivateOrigins", []),
         :ok <- validate_origins(allowed),
         :ok <- validate_origins(approved) do
      if Enum.all?(approved, &(&1 in allowed)),
        do: {:ok, allowed, approved},
        else: {:error, :invalid_origin_policy}
    end
  end

  defp policy_origins(_), do: {:error, :invalid_origin_policy}

  defp policy_field(policy, atom_key, json_key, default) do
    case {Map.fetch(policy, atom_key), Map.fetch(policy, json_key)} do
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {{:ok, value}, {:ok, value}} -> {:ok, value}
      {:error, :error} when default != :required -> {:ok, default}
      _ -> {:error, :invalid_origin_policy}
    end
  end

  defp validate_origins(origins) when is_list(origins) do
    bounded = Enum.take(origins, @max_policy_origins + 1)
    count = length(bounded)

    if count <= @max_policy_origins and
         Enum.all?(bounded, fn
           origin when is_binary(origin) and byte_size(origin) <= @max_origin_bytes ->
             canonical_origin(origin) == {:ok, origin}

           _ ->
             false
         end) and MapSet.size(MapSet.new(bounded)) == count do
      :ok
    else
      {:error, :invalid_origin_policy}
    end
  end

  defp validate_origins(_), do: {:error, :invalid_origin_policy}

  defp require_allowed(origin, allowed) do
    if origin in allowed, do: :ok, else: {:error, :origin_not_allowed}
  end

  defp resolve(host, opts) when is_list(opts) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} -> {:ok, [address]}
      {:error, _} -> call_resolver(host, Keyword.get(opts, :resolver, &system_resolve/1))
    end
  rescue
    _ -> {:error, :dns_resolution_failed}
  catch
    _, _ -> {:error, :dns_resolution_failed}
  end

  defp resolve(_, _), do: {:error, :dns_resolution_failed}

  defp call_resolver(host, resolver) when is_function(resolver, 1) do
    case resolver.(host) do
      {:ok, addresses} when is_list(addresses) ->
        bounded = Enum.take(addresses, @max_addresses + 1)

        cond do
          length(bounded) > @max_addresses -> {:error, :too_many_dns_addresses}
          bounded == [] -> {:error, :dns_resolution_failed}
          true -> {:ok, bounded}
        end

      _ ->
        {:error, :dns_resolution_failed}
    end
  end

  defp call_resolver(_, _), do: {:error, :dns_resolution_failed}

  defp system_resolve(host) do
    hostname = String.to_charlist(host)
    ipv4 = :inet.getaddrs(hostname, :inet)
    ipv6 = :inet.getaddrs(hostname, :inet6)

    with {:ok, v4} <- dns_family(ipv4),
         {:ok, v6} <- dns_family(ipv6) do
      {:ok, v4 ++ v6}
    end
  end

  defp dns_family({:ok, addresses}) when is_list(addresses), do: {:ok, addresses}
  defp dns_family({:error, reason}) when reason in [:nxdomain, :enodata], do: {:ok, []}
  defp dns_family(_), do: {:error, :dns_resolution_failed}

  defp validate_addresses(addresses, approved?) do
    cond do
      not Enum.all?(addresses, &valid_address?/1) -> {:error, :invalid_dns_answer}
      approved? or Enum.all?(addresses, &public_address?/1) -> :ok
      true -> {:error, :destination_not_public}
    end
  end

  defp valid_address?(address) when is_tuple(address) and tuple_size(address) == 4 do
    address |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) and &1 in 0..255))
  end

  defp valid_address?(address) when is_tuple(address) and tuple_size(address) == 8 do
    address |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) and &1 in 0..65_535))
  end

  defp valid_address?(_), do: false

  # IPv4-mapped IPv6 has exactly the IPv4 destination's classification.
  defp public_address?({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    public_address?({div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)})
  end

  defp public_address?({a, b, c, _d}) do
    not (a in [0, 10, 127] or a >= 224 or
           (a == 100 and b in 64..127) or
           (a == 169 and b == 254) or
           (a == 172 and b in 16..31) or
           (a == 192 and b == 0 and c in [0, 2]) or
           (a == 192 and b == 88 and c == 99) or
           (a == 192 and b == 168) or
           (a == 198 and b in [18, 19]) or
           (a == 198 and b == 51 and c == 100) or
           (a == 203 and b == 0 and c == 113))
  end

  # Only allocated global unicast is eligible. Exclude special-protocol space,
  # documentation and deprecated 6to4 (which can conceal an embedded IPv4 hop).
  defp public_address?({first, second, _, _, _, _, _, _}) do
    first in 0x2000..0x3FFF and
      not ((first == 0x2001 and second < 0x0200) or
             (first == 0x2001 and second == 0x0DB8) or
             first == 0x2002 or
             (first == 0x3FFF and second < 0x1000))
  end
end
