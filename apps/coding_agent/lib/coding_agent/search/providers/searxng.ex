defmodule CodingAgent.Search.Providers.Searxng do
  @moduledoc "User-configured SearXNG JSON search provider."

  @behaviour CodingAgent.Search.Provider

  alias CodingAgent.Search.Result

  @impl true
  def id, do: "searxng"

  @impl true
  def capabilities, do: [:search]

  @impl true
  def available?(:search, %{base_url: base_url}) when is_binary(base_url) and base_url != "",
    do: :ok

  def available?(:search, _context), do: {:error, :missing_searxng_base_url}

  @impl true
  def search(request, context) do
    started_ms = System.monotonic_time(:millisecond)

    query = %{"q" => request.query, "format" => "json"}

    query =
      if request.search_lang, do: Map.put(query, "language", request.search_lang), else: query

    url = String.trim_trailing(context.base_url, "/") <> "/search?" <> URI.encode_query(query)

    headers =
      [{"accept", "application/json"}]
      |> maybe_authorization(Map.get(context, :api_key))

    opts = [
      headers: headers,
      connect_options: [timeout: context.timeout_ms],
      receive_timeout: context.timeout_ms
    ]

    case context.http_get.(url, opts) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        results =
          response.body
          |> Result.decode_json()
          |> Map.get("results", [])
          |> Enum.take(request.count)
          |> Enum.map(&map_result(&1, request))

        {:ok, Result.search_results(request.query, id(), results, started_ms)}

      {:ok, %Req.Response{status: status}} ->
        {:error, "SearXNG search error (#{status})"}

      {:error, reason} ->
        {:error, "SearXNG search request failed: #{Result.format_reason(reason)}"}

      other ->
        {:error, "Unexpected SearXNG search result: #{inspect(other)}"}
    end
  end

  defp map_result(entry, request) when is_map(entry) do
    Result.mapped_result(
      Map.get(entry, "title"),
      Map.get(entry, "url"),
      Map.get(entry, "content"),
      title_max_chars: request.snippet_max_chars,
      description_max_chars: request.max_chars,
      published: Map.get(entry, "publishedDate") || Map.get(entry, "published_date")
    )
  end

  defp map_result(_, _request), do: nil

  defp maybe_authorization(headers, key) when is_binary(key) and key != "",
    do: headers ++ [{"authorization", "Bearer #{key}"}]

  defp maybe_authorization(headers, _), do: headers
end
