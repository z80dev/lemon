defmodule CodingAgent.Search.Providers.Keenable do
  @moduledoc """
  Keenable Search API provider (`KEENABLE_API_KEY`), using the keyed
  `POST /v1/search` endpoint. Snippets prefer `description`, falling back to
  the page `snippet`.
  """

  @behaviour CodingAgent.Search.Provider

  alias CodingAgent.Search.Operators
  alias CodingAgent.Search.Providers.KeyedHttp
  alias CodingAgent.Search.Result

  @endpoint "https://api.keenable.ai/v1/search"

  @impl true
  def id, do: "keenable"

  @impl true
  def capabilities, do: [:search]

  @impl true
  def search_features, do: %{operators: Operators.syntax(), freshness: []}

  @impl true
  def available?(:search, context),
    do: KeyedHttp.available?(id(), "KEENABLE_API_KEY", context)

  @impl true
  def search(request, context) do
    started_ms = System.monotonic_time(:millisecond)
    body = %{"query" => request.query, "max_results" => request.count}

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
    snippet =
      case item["description"] do
        description when is_binary(description) and description != "" -> description
        _ -> item["snippet"]
      end

    KeyedHttp.mapped(request, item["title"] || url, url, snippet)
  end

  defp map_item(_item, _request), do: nil
end
