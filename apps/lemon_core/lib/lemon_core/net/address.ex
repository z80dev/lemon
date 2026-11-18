defmodule LemonCore.Net.Address do
  @moduledoc """
  The one outbound address policy shared by every Lemon network guard.

  A destination is classified as `:public`, `:private` or `:metadata`:

    * `:metadata` — link-local space (`169.254.0.0/16`, `fe80::/10`) and known
      cloud metadata endpoints (`100.100.100.200`, `fd00:ec2::254`, the
      `metadata`, `metadata.goog` and `metadata.google.internal` names). Never
      reachable, whatever the caller allows.
    * `:private` — every address that is not allocated global unicast:
      loopback, RFC 1918, CGNAT, multicast, reserved, documentation, benchmark,
      ULA, site-local, Teredo/ORCHID and other special-purpose IPv6, and all of
      6to4 (`2002::/16`, which can conceal an embedded IPv4 hop). `localhost`
      names are private without resolution.
    * `:public` — everything else.

  IPv4 literals are recognised in every `inet_aton` alias form (`2852039166`,
  `0xA9FEA9FE`, octal and short dotted forms), and IPv6 forms embedding an IPv4
  destination (IPv4-mapped, IPv4-compatible, NAT64 `64:ff9b::/96`) are
  classified as that IPv4 address. A hostname takes the most restrictive class
  of all its A and AAAA answers.

  DNS failure is never treated as public: an unresolvable host, an empty
  answer, a malformed answer or more than #{64} addresses is an error.

  The managed browser's egress proxy enforces the same policy at connection
  time through a TypeScript port in
  `clients/lemon-browser-node/src/destination-guard.ts`; change both together
  (its tests mirror `address_test.exs`).
  """

  import Bitwise

  @max_addresses 64
  @default_dns_timeout_ms 5_000
  @max_host_bytes 1_024
  @metadata_names ["metadata", "metadata.goog", "metadata.google.internal"]
  @localhost_names [
    "localhost",
    "localhost.localdomain",
    "localhost6",
    "ip6-localhost",
    "ip6-loopback"
  ]

  @type class :: :public | :private | :metadata
  @type resolver :: (String.t() -> {:ok, [:inet.ip_address()]} | {:error, term()})
  @type dns_error ::
          :invalid_host | :dns_resolution_failed | :too_many_dns_addresses | :dns_timeout

  @doc """
  Parses an IP literal host (brackets allowed) in any alias form.
  """
  @spec parse_literal(term()) :: {:ok, :inet.ip_address()} | :error
  def parse_literal(host) when is_binary(host) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]")

    if host != "" and byte_size(host) <= @max_host_bytes and not String.contains?(host, "%") do
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, address} -> {:ok, address}
        {:error, _} -> parse_inet_aton(host)
      end
    else
      :error
    end
  end

  def parse_literal(_host), do: :error

  # inet_aton: 1-4 dot-separated parts, each decimal, 0x-hex or 0-octal; the
  # last part fills the remaining bytes. OTP rejects some of these forms
  # (`0x7f.0x0.0x0.0x1`) that resolvers and browsers still accept.
  defp parse_inet_aton(host) do
    parts = String.split(host, ".")

    with true <- length(parts) in 1..4,
         {:ok, values} <- parse_aton_parts(parts, []),
         {:ok, integer} <- aton_integer(values) do
      {:ok,
       {integer >>> 24 &&& 0xFF, integer >>> 16 &&& 0xFF, integer >>> 8 &&& 0xFF,
        integer &&& 0xFF}}
    else
      _ -> :error
    end
  end

  defp parse_aton_parts([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_aton_parts([part | rest], acc) do
    parsed =
      cond do
        Regex.match?(~r/\A0[xX][0-9a-fA-F]{1,8}\z/, part) ->
          String.to_integer(binary_part(part, 2, byte_size(part) - 2), 16)

        Regex.match?(~r/\A0[0-7]{1,11}\z/, part) ->
          String.to_integer(part, 8)

        Regex.match?(~r/\A[1-9][0-9]{0,9}\z|\A0\z/, part) ->
          String.to_integer(part)

        true ->
          nil
      end

    if parsed, do: parse_aton_parts(rest, [parsed | acc]), else: :error
  end

  defp aton_integer(values) do
    {heads, [last]} = Enum.split(values, -1)
    tail_bits = 8 * (4 - length(heads))

    if Enum.all?(heads, &(&1 <= 255)) and last < 1 <<< tail_bits do
      {:ok, Enum.reduce(heads, 0, fn byte, acc -> acc <<< 8 ||| byte end) <<< tail_bits ||| last}
    else
      :error
    end
  end

  @doc "Classifies one IP address."
  @spec classify(:inet.ip_address()) :: class()
  def classify(address) do
    case embedded_ipv4(address) do
      {:ok, ipv4} -> classify_ipv4(ipv4)
      :error -> classify_ipv6(address)
    end
  end

  @doc "True only for allocated global unicast addresses."
  @spec public?(:inet.ip_address()) :: boolean()
  def public?(address), do: valid_address?(address) and classify(address) == :public

  @doc "Returns the most restrictive class of a list of addresses."
  @spec classify_all([:inet.ip_address()]) :: class()
  def classify_all(addresses) when is_list(addresses) do
    addresses |> Enum.map(&classify/1) |> Enum.reduce(:public, &stricter/2)
  end

  @doc """
  Resolves and classifies a host (DNS name or IP literal).

  Returns the class and the addresses a connection may use. Metadata and
  `localhost` names are classified by name and return no addresses. Options:
  `:resolver` replaces the system resolver (tests and callers that already hold
  a trusted resolver).
  """
  @spec classify_host(term(), keyword()) ::
          {:ok, class(), [:inet.ip_address()]} | {:error, dns_error()}
  def classify_host(host, opts \\ [])

  def classify_host(host, opts) when is_binary(host) and is_list(opts) do
    case parse_literal(String.trim_trailing(host, ".")) do
      {:ok, address} ->
        {:ok, classify(address), [address]}

      :error ->
        case canonical_name(host) do
          {:ok, name} when name in @metadata_names ->
            {:ok, :metadata, []}

          {:ok, name} ->
            if localhost_name?(name) do
              {:ok, :private, []}
            else
              with {:ok, addresses} <- resolve(name, opts),
                   do: {:ok, classify_all(addresses), addresses}
            end

          :error ->
            {:error, :invalid_host}
        end
    end
  end

  def classify_host(_host, _opts), do: {:error, :invalid_host}

  @doc """
  Authorizes a host for an outbound connection and returns the addresses to
  pin.

  Public destinations are always allowed. `allow_private: true` additionally
  allows private ones. Metadata destinations are always refused. Errors are
  classified atoms only.
  """
  @spec authorize(term(), keyword()) ::
          {:ok, [:inet.ip_address(), ...]}
          | {:error, dns_error() | :destination_not_public | :metadata_blocked}
  def authorize(host, opts \\ []) do
    with {:ok, class, addresses} <- classify_host(host, opts) do
      cond do
        class == :metadata ->
          {:error, :metadata_blocked}

        class == :private and Keyword.get(opts, :allow_private, false) != true ->
          {:error, :destination_not_public}

        # Only localhost names have no addresses; they pin to loopback.
        addresses == [] ->
          {:ok, [{127, 0, 0, 1}]}

        true ->
          {:ok, Enum.sort(addresses)}
      end
    end
  end

  @doc """
  Resolves a DNS name to A and AAAA addresses, failing closed.

  An absent record in one family is not an error, but a resolver failure in
  either family, an empty answer, a malformed answer, more than
  #{@max_addresses} addresses, or no answer within `timeout_ms` (default
  #{@default_dns_timeout_ms} ms; the lookup process is killed) is.
  """
  @spec resolve(String.t(), keyword()) ::
          {:ok, [:inet.ip_address(), ...]}
          | {:error, :dns_resolution_failed | :too_many_dns_addresses | :dns_timeout}
  def resolve(host, opts \\ []) when is_binary(host) do
    resolver = Keyword.get(opts, :resolver) || (&system_resolve/1)
    timeout = Keyword.get(opts, :timeout_ms, @default_dns_timeout_ms)

    case call_with_timeout(fn -> resolver.(host) end, timeout) do
      {:ok, {:ok, addresses}} when is_list(addresses) ->
        bounded = Enum.take(addresses, @max_addresses + 1)
        unique = Enum.uniq(bounded)

        cond do
          length(bounded) > @max_addresses -> {:error, :too_many_dns_addresses}
          unique == [] -> {:error, :dns_resolution_failed}
          not Enum.all?(unique, &valid_address?/1) -> {:error, :dns_resolution_failed}
          true -> {:ok, unique}
        end

      :timeout ->
        {:error, :dns_timeout}

      _ ->
        {:error, :dns_resolution_failed}
    end
  end

  # Runs the lookup in an unlinked process so that neither a hung resolver nor
  # a crashing one can outlive the deadline or take the caller down.
  defp call_with_timeout(fun, timeout) when is_integer(timeout) and timeout > 0 do
    caller = self()
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, fun.()}
          rescue
            _ -> :error
          catch
            _, _ -> :error
          end

        send(caller, {tag, result})
      end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :error
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        receive do
          {^tag, _} -> :ok
        after
          0 -> :ok
        end

        :timeout
    end
  end

  defp call_with_timeout(_fun, _timeout), do: :timeout

  @doc false
  def system_resolve(host) do
    hostname = String.to_charlist(host)

    with {:ok, v4} <- dns_family(:inet.getaddrs(hostname, :inet)),
         {:ok, v6} <- dns_family(:inet.getaddrs(hostname, :inet6)) do
      {:ok, v4 ++ v6}
    end
  end

  defp dns_family({:ok, addresses}) when is_list(addresses), do: {:ok, addresses}
  defp dns_family({:error, reason}) when reason in [:nxdomain, :enodata], do: {:ok, []}
  defp dns_family(_), do: {:error, :dns_resolution_failed}

  @doc "True for `localhost` and its aliases, including `*.localhost`."
  @spec localhost_name?(String.t()) :: boolean()
  def localhost_name?(name) when is_binary(name),
    do: name in @localhost_names or String.ends_with?(name, ".localhost")

  defp canonical_name(host) do
    name = host |> String.trim() |> String.downcase() |> String.trim_trailing(".")

    if name != "" and byte_size(name) <= 253 and
         Regex.match?(~r/\A[a-z0-9_]([a-z0-9_.-]*[a-z0-9_])?\z/, name) do
      {:ok, name}
    else
      :error
    end
  end

  defp stricter(:metadata, _), do: :metadata
  defp stricter(_, :metadata), do: :metadata
  defp stricter(:private, _), do: :private
  defp stricter(_, :private), do: :private
  defp stricter(_, _), do: :public

  defp valid_address?({_, _, _, _} = address),
    do: address |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) and &1 in 0..255))

  defp valid_address?({_, _, _, _, _, _, _, _} = address),
    do: address |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) and &1 in 0..0xFFFF))

  defp valid_address?(_), do: false

  # IPv6 forms that deliver to an embedded IPv4 destination.
  defp embedded_ipv4({_, _, _, _} = address), do: {:ok, address}
  defp embedded_ipv4({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: {:ok, ipv4(hi, lo)}
  defp embedded_ipv4({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: {:ok, ipv4(hi, lo)}

  # IPv4-compatible (deprecated ::a.b.c.d), excluding :: and ::1.
  defp embedded_ipv4({0, 0, 0, 0, 0, 0, hi, lo}) when hi != 0 or lo > 1,
    do: {:ok, ipv4(hi, lo)}

  defp embedded_ipv4(_), do: :error

  defp ipv4(hi, lo), do: {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}

  defp classify_ipv4({169, 254, _, _}), do: :metadata
  defp classify_ipv4({100, 100, 100, 200}), do: :metadata

  defp classify_ipv4({a, b, c, _d}) do
    if a in [0, 10, 127] or a >= 224 or
         (a == 100 and b in 64..127) or
         (a == 172 and b in 16..31) or
         (a == 192 and b == 0 and c in [0, 2]) or
         (a == 192 and b == 88 and c == 99) or
         (a == 192 and b == 168) or
         (a == 198 and b in [18, 19]) or
         (a == 198 and b == 51 and c == 100) or
         (a == 203 and b == 0 and c == 113),
       do: :private,
       else: :public
  end

  defp classify_ipv6({0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x254}), do: :metadata

  defp classify_ipv6({first, _, _, _, _, _, _, _}) when (first &&& 0xFFC0) == 0xFE80,
    do: :metadata

  # 6to4 is never public, and is metadata when it embeds a metadata address.
  defp classify_ipv6({0x2002, hi, lo, _, _, _, _, _}) do
    if classify_ipv4(ipv4(hi, lo)) == :metadata, do: :metadata, else: :private
  end

  # Only allocated global unicast (2000::/3) is public; exclude special-purpose
  # 2001::/23 (Teredo, ORCHID, benchmarking), documentation and 3fff::/20.
  defp classify_ipv6({first, second, _, _, _, _, _, _}) do
    if first in 0x2000..0x3FFF and
         not ((first == 0x2001 and second < 0x0200) or
                (first == 0x2001 and second == 0x0DB8) or
                (first == 0x3FFF and second < 0x1000)),
       do: :public,
       else: :private
  end
end
