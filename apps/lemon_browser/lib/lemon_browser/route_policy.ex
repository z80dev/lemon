defmodule LemonBrowser.RoutePolicy do
  @moduledoc """
  Shared browser navigation route classification and guardrails.

  http(s) targets are classified by `LemonCore.Net.Address`, the one outbound
  address policy: IP literals in every alias form (`2852039166`, `0xa9fea9fe`,
  octal dotted, IPv4-mapped, IPv4-compatible, NAT64 and 6to4 IPv6) are
  classified as their embedded destination, and any other hostname is
  resolved with every returned address checked. Link-local (`169.254.0.0/16`,
  `fe80::/10`) and known cloud metadata addresses and names are refused on
  every route, as is any hostname whose resolution fails. Only `localhost`
  names skip resolution: browsers pin them to loopback.

  This is a pre-check: the browser resolves the host again when it connects.
  Chrome launched by the Node driver is bound at connection time by the
  driver's egress proxy; attached and hosted browsers are not (see
  `docs/tools/browser.md`, "Egress enforcement").
  """

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
    resolver =
      Keyword.get(opts, :resolve_host) ||
        Application.get_env(:lemon_browser, :resolve_host)

    case LemonCore.Net.Address.classify_host(host, resolver: resolver) do
      {:ok, :metadata, _addresses} -> {:ok, %{metadata: true, private: true}}
      {:ok, :private, _addresses} -> {:ok, %{metadata: false, private: true}}
      {:ok, :public, _addresses} -> {:ok, %{metadata: false, private: false}}
      {:error, :invalid_host} -> {:error, "browser navigation url must include a host"}
      {:error, _} -> {:error, "browser navigation could not resolve host: #{host}"}
    end
  end
end
