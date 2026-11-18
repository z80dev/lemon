defmodule LemonBrowser.RoutePolicy do
  @moduledoc """
  Shared browser navigation route classification and guardrails.

  http(s) targets are classified on canonical addresses, never on the host
  string: the host is lower-cased and stripped of trailing dots, IP literals in
  every alias form (`2852039166`, `0xa9fea9fe`, octal dotted, IPv4-mapped,
  IPv4-compatible and NAT64 IPv6) are normalized to a canonical address, and
  any other hostname is resolved with every returned address checked.
  Link-local (`169.254.0.0/16`, `fe80::/10`) and known cloud metadata
  addresses are refused on every route, as is any hostname whose resolution
  fails. Only `localhost` names skip resolution: browsers pin them to loopback.

  This is a pre-check: the browser resolves the host again when it connects.
  Chrome launched by the Node driver is bound at connection time by the
  driver's egress proxy; attached and hosted browsers are not (see
  `docs/tools/browser.md`, "Egress enforcement").
  """

  @metadata_hostnames ["metadata", "metadata.google.internal", "metadata.goog"]

  @typedoc "`resolve_host:` overrides DNS resolution (tests); defaults to the system resolver."
  @type option :: {:resolve_host, (String.t() -> {:ok, [:inet.ip_address()]} | {:error, term()})}

  @type policy :: %{
          route: String.t(),
          effective_route: String.t(),
          target_kind: String.t(),
          scheme: String.t() | nil,
          private: boolean(),
          metadata: boolean()
        }

  @spec validate_navigation(String.t(), String.t() | nil, [option()]) ::
          {:ok, policy()} | {:error, String.t()}
  def validate_navigation(url, route \\ "auto", opts \\ [])

  def validate_navigation(url, route, opts) when is_binary(url) do
    with {:ok, route} <- navigation_route(route),
         {:ok, target} <- classify_navigation_target(url, opts),
         :ok <- enforce_navigation_route(route, target) do
      {:ok,
       %{
         route: route,
         effective_route: effective_navigation_route(target),
         target_kind: target.kind,
         scheme: target.scheme,
         private: target.private,
         metadata: target.metadata
       }}
    end
  end

  def validate_navigation(_url, _route, _opts), do: {:error, "url is required"}

  @spec safe(policy()) :: map()
  def safe(policy) when is_map(policy) do
    %{
      "route" => policy.route,
      "effectiveRoute" => policy.effective_route,
      "targetKind" => policy.target_kind,
      "private" => policy.private,
      "metadata" => policy.metadata
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, false] end)
    |> Map.new()
  end

  defp navigation_route(nil), do: {:ok, "auto"}
  defp navigation_route(""), do: {:ok, "auto"}
  defp navigation_route(route) when route in ["auto", "public", "local"], do: {:ok, route}

  defp navigation_route(route) when is_binary(route),
    do: {:error, "unsupported browser navigation route: #{route}"}

  defp navigation_route(_route), do: {:error, "browser navigation route must be a string"}

  defp classify_navigation_target(url, opts) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["data", "file", "about", "blob"] ->
        {:ok,
         %{
           kind: "local_document",
           scheme: scheme,
           private: true,
           metadata: false
         }}

      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        with {:ok, %{metadata: metadata, private: private}} <- classify_host(host, opts) do
          {:ok,
           %{
             kind: if(private, do: "private_network", else: "public_network"),
             scheme: scheme,
             private: private,
             metadata: metadata
           }}
        end

      %URI{scheme: scheme} when is_binary(scheme) ->
        {:error, "unsupported browser navigation scheme: #{scheme}"}

      _ ->
        {:error, "browser navigation url must include a supported scheme"}
    end
  end

  defp enforce_navigation_route(_route, %{metadata: true}) do
    {:error, "browser navigation blocked metadata endpoint"}
  end

  defp enforce_navigation_route("public", %{kind: "public_network"}), do: :ok

  defp enforce_navigation_route("public", _target),
    do: {:error, "browser navigation requires a public http(s) URL"}

  defp enforce_navigation_route("local", %{kind: "local_document"}), do: :ok
  defp enforce_navigation_route("local", %{kind: "private_network"}), do: :ok

  defp enforce_navigation_route("local", _target),
    do: {:error, "browser navigation requires a local or private URL"}

  defp enforce_navigation_route("auto", _target), do: :ok

  defp effective_navigation_route(%{kind: "public_network"}), do: "public"
  defp effective_navigation_route(_target), do: "local"

  defp classify_host(host, opts) do
    host = host |> String.downcase() |> String.trim_trailing(".")

    cond do
      host == "" ->
        {:error, "browser navigation url must include a host"}

      host in @metadata_hostnames ->
        {:ok, %{metadata: true, private: true}}

      true ->
        case parse_ip(host) do
          {:ok, address} ->
            {:ok, classify_addresses([address])}

          :error ->
            if localhost_name?(host) do
              {:ok, %{metadata: false, private: true}}
            else
              resolve_and_classify(host, opts)
            end
        end
    end
  end

  defp resolve_and_classify(host, opts) do
    resolver =
      Keyword.get(opts, :resolve_host) ||
        Application.get_env(:lemon_browser, :resolve_host, &resolve_host/1)

    case resolver.(host) do
      {:ok, [_ | _] = addresses} ->
        if Enum.all?(addresses, &:inet.is_ip_address/1) do
          {:ok, classify_addresses(addresses)}
        else
          {:error, "browser navigation could not resolve host: #{host}"}
        end

      _ ->
        {:error, "browser navigation could not resolve host: #{host}"}
    end
  end

  @doc false
  def resolve_host(host) do
    charlist = String.to_charlist(host)

    addresses =
      for family <- [:inet, :inet6],
          {:ok, found} <- [:inet.getaddrs(charlist, family)],
          address <- found,
          uniq: true,
          do: address

    if addresses == [], do: {:error, :nxdomain}, else: {:ok, addresses}
  end

  defp classify_addresses(addresses) do
    canonical = Enum.map(addresses, &canonical_ip/1)
    metadata = Enum.any?(canonical, &metadata_ip?/1)
    %{metadata: metadata, private: metadata or Enum.any?(canonical, &private_ip?/1)}
  end

  defp localhost_name?(host),
    do: host in ["localhost", "ip6-localhost"] or String.ends_with?(host, ".localhost")

  # `:inet.parse_address/1` accepts every inet_aton IPv4 alias (single number,
  # hex, octal, short dotted forms) and all IPv6 notations.
  defp parse_ip(host) do
    host
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, address} -> {:ok, address}
      _ -> :error
    end
  end

  # IPv4-mapped (::ffff:a.b.c.d), NAT64 (64:ff9b::a.b.c.d) and IPv4-compatible
  # (::a.b.c.d, excluding :: and ::1) addresses reach the embedded IPv4 host.
  defp canonical_ip({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: embedded_ipv4(hi, lo)
  defp canonical_ip({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: embedded_ipv4(hi, lo)

  defp canonical_ip({0, 0, 0, 0, 0, 0, hi, lo}) when hi != 0 or lo > 1,
    do: embedded_ipv4(hi, lo)

  defp canonical_ip(address), do: address

  defp embedded_ipv4(hi, lo),
    do: {Bitwise.bsr(hi, 8), Bitwise.band(hi, 0xFF), Bitwise.bsr(lo, 8), Bitwise.band(lo, 0xFF)}

  defp metadata_ip?({169, 254, _, _}), do: true
  defp metadata_ip?({100, 100, 100, 200}), do: true
  defp metadata_ip?({0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x254}), do: true

  defp metadata_ip?({first, _, _, _, _, _, _, _}) when Bitwise.band(first, 0xFFC0) == 0xFE80,
    do: true

  defp metadata_ip?(_address), do: false

  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({172, second, _, _}) when second >= 16 and second <= 31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({100, second, _, _}) when second >= 64 and second <= 127, do: true
  defp private_ip?({0, _, _, _}), do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true

  defp private_ip?({first, _, _, _, _, _, _, _}) when Bitwise.band(first, 0xFE00) == 0xFC00,
    do: true

  defp private_ip?(_address), do: false
end
