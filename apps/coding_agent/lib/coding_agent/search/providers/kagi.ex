defmodule CodingAgent.Search.Providers.Kagi do
  @moduledoc """
  Kagi Search API provider (`KAGI_API_KEY`), using the V1 `POST /api/v1/search`
  endpoint. Web results come first, then video/news/infobox buckets.
  """

  @behaviour CodingAgent.Search.Provider

  alias CodingAgent.Search.Operators
  alias CodingAgent.Search.Providers.KeyedHttp
  alias CodingAgent.Search.Result

  @endpoint "https://kagi.com/api/v1/search"
  @buckets [{"search", nil}, {"video", "[Video] "}, {"news", "[News] "}, {"infobox", "[Info] "}]

  @impl true
  def id, do: "kagi"

  @impl true
  def capabilities, do: [:search]

  @impl true
  def search_features,
    do: %{
      operators: Operators.syntax() ++ [:after, :before],
      freshness: [:relative, :range]
    }

  @impl true
  def available?(:search, context), do: KeyedHttp.available?(id(), "KAGI_API_KEY", context)

  @impl true
  def search(request, context) do
    started_ms = System.monotonic_time(:millisecond)
    body = %{"query" => request.query, "limit" => request.count}
    {first, last} = Operators.dates(request)

    filters =
      %{}
      |> Operators.put_if("after", first)
      |> Operators.put_if("before", last)

    body = if filters == %{}, do: body, else: Map.put(body, "filters", filters)

    opts =
      KeyedHttp.request_opts(context, [
        {"content-type", "application/json"},
        {"accept", "application/json"},
        {"authorization", "Bearer " <> context.api_key}
      ])

    KeyedHttp.handle("Kagi", context.http_post.(@endpoint, [{:json, body} | opts]), fn decoded ->
      data = if is_map(decoded["data"]), do: decoded["data"], else: %{}

      results =
        @buckets
        |> Enum.flat_map(fn {bucket, prefix} ->
          data
          |> Map.get(bucket)
          |> KeyedHttp.list()
          |> Enum.map(&map_item(&1, prefix, request))
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(request.count)

      {:ok, Result.search_results(request.query, id(), results, started_ms)}
    end)
  end

  defp map_item(%{"url" => url} = item, prefix, request) when is_binary(url) and url != "" do
    title = if is_binary(item["title"]), do: (prefix || "") <> item["title"], else: url
    KeyedHttp.mapped(request, title, url, item["snippet"], item["time"])
  end

  defp map_item(_item, _prefix, _request), do: nil
end
