defmodule LemonCore.Context.URLFetcher do
  @moduledoc """
  Bounded public-HTTP fetches for context references.

  Fetches go through `LemonCore.Net.HTTP`, which authorizes every hop with
  `LemonCore.Net.Address`, pins the connection to the validated IP (keeping
  the original Host header and TLS identity) and follows redirects manually,
  re-authorizing each one. URLs carrying credentials are rejected up front.

  Errors are reported with this module's vocabulary: `:ssrf_blocked`,
  `:dns_failed`, `:redirect_limit`, `:redirect_loop`, `:invalid_redirect`,
  `:input_too_large`, `:invalid_url`, `:url_credentials_forbidden`,
  `{:http_status, status}` and `:network_error`.

  Test seams: `:resolve_fun` (host -> `{:ok, [ip]}`) and `:send_fun` (the
  `LemonCore.Net.HTTP` `:send` transport override).
  """

  alias LemonCore.Net.HTTP

  @default_max_bytes 8_000_000
  @default_timeout_ms 10_000
  @default_redirects 3
  @headers [
    {"user-agent", "Lemon-Context/1"},
    {"accept", "*/*"},
    {"accept-encoding", "identity"}
  ]

  @spec fetch(String.t(), keyword()) :: {:ok, binary(), map()} | {:error, term()}
  def fetch(url, opts \\ []) when is_binary(url) do
    with :ok <- reject_credentials(String.trim(url)),
         {:ok, uri} <- HTTP.parse_url(String.trim(url)),
         {:ok, response} <- HTTP.request(:get, canonical_url(uri), http_opts(opts)) do
      case response do
        %{status: status, body: body, headers: headers} when status in 200..299 ->
          {:ok, body,
           %{
             final_url: redacted_url(response.url),
             status: status,
             content_type: header_value(headers, "content-type"),
             redirects: response.redirects
           }}

        %{status: status} ->
          {:error, {:http_status, status}}
      end
    else
      {:error, reason} -> {:error, map_error(reason)}
    end
  end

  defp http_opts(opts) do
    [
      max_redirects: positive(opts[:max_redirects], @default_redirects),
      max_body_bytes: positive(opts[:max_input_bytes], @default_max_bytes),
      timeout_ms: positive(opts[:timeout_ms], @default_timeout_ms),
      headers: @headers
    ]
    |> put_present(:resolver, opts[:resolve_fun])
    |> put_present(:send, opts[:send_fun])
  end

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)
  # Redirect-loop detection compares serialized URLs, so the initial URL must
  # use the same canonical form as redirect targets.
  defp canonical_url(%URI{} = uri),
    do: URI.to_string(%URI{uri | host: String.downcase(uri.host), fragment: nil})

  defp reject_credentials(url) do
    case URI.parse(url) do
      %URI{userinfo: userinfo} when userinfo not in [nil, ""] ->
        {:error, :url_credentials_forbidden}

      _ ->
        :ok
    end
  end

  defp map_error(:url_credentials_forbidden), do: :url_credentials_forbidden
  defp map_error(:metadata_blocked), do: :ssrf_blocked
  defp map_error(:destination_not_public), do: :ssrf_blocked
  defp map_error(:dns_resolution_failed), do: :dns_failed
  defp map_error(:too_many_dns_addresses), do: :dns_failed
  defp map_error(:invalid_host), do: :dns_failed
  defp map_error(:too_many_redirects), do: :redirect_limit
  defp map_error(:invalid_redirect), do: :invalid_redirect
  defp map_error(:redirect_loop), do: :redirect_loop
  defp map_error({:body_too_large, _}), do: :input_too_large
  defp map_error(:invalid_url), do: :invalid_url
  defp map_error(_), do: :network_error

  defp header_value(headers, name) do
    Enum.find_value(headers, fn {key, value} -> if key == name, do: value end)
  end

  defp redacted_url(url) do
    uri = URI.parse(url)
    %URI{uri | userinfo: nil, query: nil, fragment: nil} |> URI.to_string()
  end

  defp positive(value, _default) when is_integer(value) and value >= 0, do: value
  defp positive(_, default), do: default
end
