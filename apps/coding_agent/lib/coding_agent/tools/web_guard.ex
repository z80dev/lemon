defmodule CodingAgent.Tools.WebGuard do
  @moduledoc false

  # Guarded GET for agent-supplied URLs. Address policy, DNS pinning, TLS,
  # redirects and the body cap all live in `LemonCore.Net.HTTP`; this module
  # only maps tool options onto it and its errors onto the tool vocabulary.

  alias LemonCore.Net.HTTP

  @type fetch_error ::
          {:invalid_url, String.t()}
          | {:ssrf_blocked, String.t()}
          | {:redirect_error, String.t()}
          | {:network_error, String.t()}
          | {:body_too_large, %{max_body_bytes: pos_integer()}}

  @redirect_statuses [301, 302, 303, 307, 308]
  @default_max_redirects 3

  @doc """
  Fetches `url` with `GET` through the pinned core fetcher.

  Options: `max_redirects` (default 3), `timeout_ms`, `max_body_bytes`,
  `headers`, `allow_private_network`, `allowed_hostnames`, `resolve_host`
  (`fn host -> {:ok, [ip]} | {:error, term}`), `cacerts` / `cacertfile`, and
  `send` (test transport override, see `LemonCore.Net.HTTP`).
  """
  @spec guarded_get(String.t(), keyword()) ::
          {:ok, HTTP.response(), String.t()} | {:error, fetch_error()}
  def guarded_get(url, opts \\ []) when is_binary(url) do
    max_redirects = max_redirects(Keyword.get(opts, :max_redirects))

    request_opts =
      [
        headers: Keyword.get(opts, :headers, []),
        max_redirects: max_redirects,
        timeout_ms: Keyword.get(opts, :timeout_ms),
        max_body_bytes: Keyword.get(opts, :max_body_bytes),
        allow_private: Keyword.get(opts, :allow_private_network, false) == true,
        allow_private_hosts: List.wrap(Keyword.get(opts, :allowed_hostnames, [])),
        resolver: Keyword.get(opts, :resolve_host),
        ssl: ssl_opts(opts),
        send: Keyword.get(opts, :send)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case HTTP.request(:get, String.trim(url), request_opts) do
      {:ok, %{status: status}} when status in @redirect_statuses ->
        # Only reachable with `max_redirects: 0`: the core returns the 3xx as-is.
        {:error, too_many_redirects(max_redirects)}

      {:ok, response} ->
        {:ok, response, response.url}

      {:error, reason} ->
        {:error, map_error(reason, max_redirects)}
    end
  end

  @spec ssrf_blocked?({:error, fetch_error()} | fetch_error() | term()) :: boolean()
  def ssrf_blocked?({:error, reason}), do: ssrf_blocked?(reason)
  def ssrf_blocked?({:ssrf_blocked, _}), do: true
  def ssrf_blocked?(_), do: false

  defp max_redirects(value) when is_integer(value) and value >= 0, do: value
  defp max_redirects(_value), do: @default_max_redirects

  defp ssl_opts(opts) do
    cond do
      Keyword.has_key?(opts, :cacerts) -> [cacerts: Keyword.get(opts, :cacerts)]
      Keyword.has_key?(opts, :cacertfile) -> [cacertfile: Keyword.get(opts, :cacertfile)]
      true -> []
    end
  end

  defp map_error(:invalid_url, _max),
    do: {:invalid_url, "Invalid URL: must be http or https"}

  defp map_error(:metadata_blocked, _max),
    do: {:ssrf_blocked, "Blocked: destination is a cloud metadata address"}

  defp map_error(:destination_not_public, _max),
    do: {:ssrf_blocked, "Blocked: resolves to private/internal IP address"}

  defp map_error(:invalid_host, _max), do: {:network_error, "Invalid hostname"}

  defp map_error(:dns_resolution_failed, _max),
    do: {:network_error, "Unable to resolve hostname"}

  defp map_error(:too_many_dns_addresses, _max),
    do: {:network_error, "Unable to resolve hostname: too many addresses"}

  defp map_error(:too_many_redirects, max), do: too_many_redirects(max)
  defp map_error(:redirect_loop, _max), do: {:redirect_error, "Redirect loop detected"}
  defp map_error(:invalid_redirect, _max), do: {:redirect_error, "Invalid redirect location"}

  defp map_error({:body_too_large, limit}, _max),
    do: {:body_too_large, %{max_body_bytes: limit}}

  defp map_error(:timeout, _max), do: {:network_error, "timeout"}

  defp map_error(:private_origin_not_owned, _max),
    do: {:network_error, "Connected peer is not the authorized destination"}

  defp map_error(_reason, _max), do: {:network_error, "HTTP request failed"}

  defp too_many_redirects(max), do: {:redirect_error, "Too many redirects (limit: #{max})"}
end
