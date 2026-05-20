defmodule LemonCore.Browser.RoutePolicy do
  @moduledoc """
  Shared browser navigation route classification and guardrails.
  """

  @type policy :: %{
          route: String.t(),
          effective_route: String.t(),
          target_kind: String.t(),
          scheme: String.t() | nil,
          private: boolean(),
          metadata: boolean()
        }

  @spec validate_navigation(String.t(), String.t() | nil) ::
          {:ok, policy()} | {:error, String.t()}
  def validate_navigation(url, route \\ "auto")

  def validate_navigation(url, route) when is_binary(url) do
    with {:ok, route} <- navigation_route(route),
         {:ok, target} <- classify_navigation_target(url),
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

  def validate_navigation(_url, _route), do: {:error, "url is required"}

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

  defp classify_navigation_target(url) do
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
        host = String.downcase(host)
        metadata = metadata_host?(host)
        private = metadata or private_host?(host)

        {:ok,
         %{
           kind: if(private, do: "private_network", else: "public_network"),
           scheme: scheme,
           private: private,
           metadata: metadata
         }}

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

  defp metadata_host?(host) do
    host in ["169.254.169.254", "metadata.google.internal", "metadata"]
  end

  defp private_host?(host) do
    host in ["localhost", "ip6-localhost"] or String.ends_with?(host, ".localhost") or
      String.ends_with?(host, ".local") or private_ip_host?(host)
  end

  defp private_ip_host?(host) do
    host
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, address} -> private_ip?(address)
      _ -> false
    end
  end

  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({172, second, _, _}) when second >= 16 and second <= 31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({0, _, _, _}), do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp private_ip?({first, _, _, _, _, _, _, _}) when Bitwise.band(first, 0xFE00) == 0xFC00,
    do: true

  defp private_ip?({first, _, _, _, _, _, _, _}) when Bitwise.band(first, 0xFFC0) == 0xFE80,
    do: true

  defp private_ip?(_address), do: false
end
