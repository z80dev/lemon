defmodule CodingAgent.Search.Providers.Jina do
  @moduledoc "Jina Search (`s.jina.ai`) provider (`JINA_API_KEY`)."

  @behaviour CodingAgent.Search.Provider

  alias CodingAgent.Search.Operators
  alias CodingAgent.Search.Providers.KeyedHttp
  alias CodingAgent.Search.Result

  @endpoint "https://s.jina.ai/"

  @impl true
  def id, do: "jina"

  @impl true
  def capabilities, do: [:search]

  @impl true
  def search_features, do: %{operators: Operators.syntax(), freshness: []}

  @impl true
  def available?(:search, context), do: KeyedHttp.available?(id(), "JINA_API_KEY", context)

  @impl true
  def search(request, context) do
    started_ms = System.monotonic_time(:millisecond)

    url =
      @endpoint <>
        URI.encode(request.query, &URI.char_unreserved?/1) <>
        "?" <> URI.encode_query(%{"count" => request.count})

    opts =
      KeyedHttp.request_opts(context, [
        {"accept", "application/json"},
        {"authorization", "Bearer " <> context.api_key},
        {"x-respond-with", "no-content"},
        {"x-retain-images", "none"}
      ])

    KeyedHttp.handle("Jina", context.http_get.(url, opts), fn decoded ->
      entries =
        case decoded do
          list when is_list(list) -> list
          %{"data" => data} -> KeyedHttp.list(data)
          _ -> []
        end

      results =
        entries
        |> Enum.map(fn
          %{"url" => url} = entry when is_binary(url) and url != "" ->
            snippet = blank_to_nil(entry["description"]) || blank_to_nil(entry["content"])
            KeyedHttp.mapped(request, entry["title"] || url, url, snippet, entry["date"])

          _ ->
            nil
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(request.count)

      {:ok, Result.search_results(request.query, id(), results, started_ms)}
    end)
  end

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: String.trim(value)
  end

  defp blank_to_nil(_value), do: nil
end
