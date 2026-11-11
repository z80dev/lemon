defmodule CodingAgent.Search.Providers.Keenable do
  @moduledoc """
  Keenable Search API provider (`KEENABLE_API_KEY`), using the keyed
  `POST /v1/search` endpoint. Snippets are capped server-side at the request's
  `max_chars` (within Keenable's 180..10000 range).
  """

  @behaviour CodingAgent.Search.Provider

  alias CodingAgent.Search.Providers.KeyedHttp
  alias CodingAgent.Search.Result

  @endpoint "https://api.keenable.ai/v1/search"
  @snippet_min 180
  @snippet_max 10_000

  @impl true
  def id, do: "keenable"

  @impl true
  def capabilities, do: [:search]

  # Keenable parses phrases, site:, -site:, -term and OR in the query. inurl:
  # and filetype: stay undeclared so they are post-filtered locally.
  @impl true
  def search_features,
    do: %{operators: [:site, :exclude_site, :phrase, :exclude, :or], freshness: []}

  @impl true
  def available?(:search, context),
    do: KeyedHttp.available?(id(), "KEENABLE_API_KEY", context)

  @impl true
  def search(request, context) do
    started_ms = System.monotonic_time(:millisecond)

    body = %{
      "query" => request.query,
      "max_results" => request.count,
      "snippet_max_length" => request.max_chars |> max(@snippet_min) |> min(@snippet_max)
    }

    opts =
      KeyedHttp.request_opts(context, [
        {"content-type", "application/json"},
        {"accept", "application/json"},
        {"x-api-key", context.api_key},
        {"x-keenable-title", "Lemon"}
      ])

    KeyedHttp.handle(
      "Keenable",
      context.http_post.(@endpoint, [{:json, body} | opts]),
      fn decoded ->
        results =
          decoded
          |> Map.get("results")
          |> KeyedHttp.list()
          |> Enum.map(&map_item(&1, request))
          |> Enum.reject(&is_nil/1)
          |> Enum.take(request.count)

        {:ok, Result.search_results(request.query, id(), results, started_ms)}
      end
    )
  end

  defp map_item(%{"url" => url} = item, request) when is_binary(url) and url != "" do
    KeyedHttp.mapped(request, item["title"] || url, url, item["snippet"], item["published_at"])
  end

  defp map_item(_item, _request), do: nil
end
