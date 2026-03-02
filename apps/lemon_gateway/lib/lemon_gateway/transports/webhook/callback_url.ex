defmodule LemonGateway.Transports.Webhook.CallbackUrl do
  @moduledoc """
  Callback URL validation and SSRF protection for webhook transport.

  Validates callback URLs by checking scheme, canonicalizing hostnames,
  and detecting private/internal IP addresses to prevent server-side
  request forgery (SSRF) attacks.
  """

  import LemonGateway.Transports.Webhook.Helpers

  @doc """
  Validates a callback URL. Returns `{:ok, normalized_url}` for valid URLs,
  `{:ok, nil}` for nil/empty URLs, or `{:error, :invalid_callback_url}` for invalid ones.

  When `allow_private_hosts` is false, URLs resolving to private/internal IPs are rejected.
  The `opts` keyword list may include a `:dns_resolver` function for testing.
  """
  @spec validate(String.t() | nil, boolean(), keyword()) ::
          {:ok, String.t() | nil} | {:error, :invalid_callback_url}
  def validate(callback_url, allow_private_hosts, opts \\ [])

  def validate(nil, _allow_private_hosts, _opts), do: {:ok, nil}
  def validate("", _allow_private_hosts, _opts), do: {:ok, nil}

  def validate(callback_url, allow_private_hosts, opts)
      when is_binary(callback_url) and is_list(opts) do
    normalized = normalize_blank(callback_url)

    with value when is_binary(value) <- normalized,
         %URI{scheme: scheme, host: host} = uri <- URI.parse(value),
         normalized_scheme when normalized_scheme in ["http", "https"] <-
           String.downcase(to_string(scheme)),
         canonical_host when is_binary(canonical_host) <- canonicalize_host(host),
         true <- allow_private_hosts || not private_callback_host?(canonical_host, opts) do
      {:ok, URI.to_string(%{uri | host: canonical_host})}
    else
      _ -> {:error, :invalid_callback_url}
    end
  rescue
    _ -> {:error, :invalid_callback_url}
  end

  def validate(_callback_url, _allow_private_hosts, _opts),
    do: {:error, :invalid_callback_url}

  # --- Host analysis ---

  defp private_callback_host?(host, opts) when is_binary(host) and is_list(opts) do
    canonical_host = canonicalize_host(host)

    cond do
      not is_binary(canonical_host) ->
        true

      localhost_variant?(canonical_host) ->
        true

      true ->
        case parse_ip(canonical_host) do
          nil ->
            canonical_host
            |> resolve_host_ips(opts)
            |> Enum.any?(&private_ip?/1)

          ip ->
            private_ip?(ip)
        end
    end
  end

  defp private_callback_host?(_, _), do: true

  defp localhost_variant?(host) when is_binary(host) do
    host in [
      "localhost",
      "localhost.localdomain",
      "localhost6",
      "ip6-localhost",
      "ip6-loopback"
    ] or String.ends_with?(host, ".localhost")
  end

  defp localhost_variant?(_), do: false

  # --- DNS resolution ---

  defp resolve_host_ips(host, opts) when is_binary(host) and is_list(opts) do
    resolver = Keyword.get(opts, :dns_resolver, &default_dns_resolver/1)

    case resolver.(host) do
      values when is_list(values) ->
        values
        |> Enum.map(&normalize_resolved_ip/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp resolve_host_ips(_, _), do: []

  defp default_dns_resolver(host) when is_binary(host) do
    host_charlist = String.to_charlist(host)

    resolve_addrs(host_charlist, :inet) ++ resolve_addrs(host_charlist, :inet6)
  end

  defp default_dns_resolver(_), do: []

  defp resolve_addrs(host, family) do
    case :inet.getaddrs(host, family) do
      {:ok, addrs} when is_list(addrs) -> addrs
      _ -> []
    end
  end

  defp normalize_resolved_ip(ip) when is_tuple(ip), do: ip

  defp normalize_resolved_ip(ip) when is_binary(ip) do
    parse_ip(ip)
  end

  defp normalize_resolved_ip(_), do: nil

  # --- IP classification ---

  defp private_ip?({a, _b, _c, _d}) when a in [0, 10, 127], do: true
  defp private_ip?({169, 254, _c, _d}), do: true
  defp private_ip?({172, b, _c, _d}) when b in 16..31, do: true
  defp private_ip?({192, 168, _c, _d}), do: true
  defp private_ip?({100, b, _c, _d}) when b in 64..127, do: true
  defp private_ip?({255, _b, _c, _d}), do: true

  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp private_ip?({0, 0, 0, 0, 0, 65_535, a, b}) do
    private_ip?({div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)})
  end

  defp private_ip?({a, _b, _c, _d, _e, _f, _g, _h}) when a in 0xFC00..0xFDFF, do: true
  defp private_ip?({a, _b, _c, _d, _e, _f, _g, _h}) when a in 0xFE80..0xFEBF, do: true
  defp private_ip?(_), do: false

  # --- Utilities ---

  defp canonicalize_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
    |> normalize_blank()
  end

  defp canonicalize_host(_), do: nil

  defp parse_ip(value) when is_binary(value) do
    value
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  defp parse_ip(_), do: nil
end
