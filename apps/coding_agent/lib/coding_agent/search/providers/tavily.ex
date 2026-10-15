defmodule CodingAgent.Search.Providers.Tavily do
  @moduledoc "Tavily Search API provider (`TAVILY_API_KEY`)."

  @behaviour CodingAgent.Search.Provider

  alias CodingAgent.Search.Providers.KeyedHttp
  alias CodingAgent.Search.Result

  @endpoint "https://api.tavily.com/search"

  @impl true
  def id, do: "tavily"

  @impl true
  def capabilities, do: [:search]

  @impl true
  def search_features,
    do: %{
      mapped_operators: [:site, :exclude_site, :after, :before],
      freshness: [:relative, :range]
    }

  @impl true
  def available?(:search, context), do: KeyedHttp.available?(id(), "TAVILY_API_KEY", context)

  @impl true
  def search(request, context) do
    started_ms = System.monotonic_time(:millisecond)

    body = %{
      "query" => request.query,
      "search_depth" => "basic",
      "max_results" => request.count,
      "include_answer" => false,
      "include_raw_content" => false
    }

    {first, last} = CodingAgent.Search.Operators.dates(request)

    body =
      body
      |> CodingAgent.Search.Operators.put_if("start_date", first)
      |> CodingAgent.Search.Operators.put_if("end_date", last)

    tokens = Map.get(request, :operator_tokens, [])

    body =
      Enum.reduce(
        [{:site, "include_domains"}, {:exclude_site, "exclude_domains"}],
        body,
        fn {kind, key}, acc ->
          domains = Enum.filter(tokens, &(&1.kind == kind)) |> Enum.map(& &1.value)
          if domains == [], do: acc, else: Map.put(acc, key, domains)
        end
      )

    opts =
      KeyedHttp.request_opts(context, [
        {"content-type", "application/json"},
        {"authorization", "Bearer " <> context.api_key}
      ])

    KeyedHttp.handle(
      "Tavily",
      context.http_post.(@endpoint, [{:json, body} | opts]),
      fn decoded ->
        results =
          decoded
          |> Map.get("results")
          |> KeyedHttp.list()
          |> Enum.map(fn
            %{} = entry ->
              KeyedHttp.mapped(
                request,
                entry["title"],
                entry["url"],
                entry["content"],
                entry["published_date"]
              )

            _ ->
              nil
          end)

        {:ok, Result.search_results(request.query, id(), results, started_ms)}
      end
    )
  end
end
