defmodule CodingAgent.Search.Providers.Kimi do
  @moduledoc """
  Kimi Code web search (`POST {base_url}/v1/search`, default
  `https://api.kimi.com/coding`), authenticated with the Kimi Code credential:
  a configured key, `KIMI_SEARCH_API_KEY`/`MOONSHOT_SEARCH_API_KEY`, or the
  `kimi_coding` model credential (subscription login, omp login or API key).
  Like omp's Kimi search provider it sends the Bing-style query with
  `limit`, `enable_page_crawling: false` and a 30 s server timeout, plus the
  Kimi CLI fingerprint every Kimi Code request carries.
  """

  @behaviour CodingAgent.Search.Provider

  alias CodingAgent.Search.Providers.KeyedHttp
  alias CodingAgent.Search.Result

  @default_base_url "https://api.kimi.com/coding"
  @max_results 20
  @server_timeout_seconds 30

  @impl true
  def id, do: "kimi"

  @impl true
  def capabilities, do: [:search]

  # Bing-flavoured: phrases, -term, site:, inurl:, filetype: are parsed upstream.
  @impl true
  def search_features,
    do: %{operators: [:site, :exclude_site, :phrase, :exclude, :inurl, :filetype], freshness: []}

  @impl true
  def available?(:search, %{api_key: key}) when is_binary(key) and key != "", do: :ok

  def available?(:search, _context) do
    {:error,
     %{
       "error" => "missing_kimi_api_key",
       "message" =>
         "websearch (kimi) needs a Kimi Code credential. Sign in with `lemon model kimi-code`, set KIMI_SEARCH_API_KEY, or configure runtime.tools.web.search.providers.kimi.api_key. A Moonshot Open Platform key is not accepted.",
       "docs" => "docs/tools/web.md"
     }}
  end

  @impl true
  def search(request, context) do
    started_ms = System.monotonic_time(:millisecond)

    endpoint =
      (Map.get(context, :base_url) || @default_base_url)
      |> String.trim_trailing("/")
      |> Kernel.<>("/v1/search")

    body = %{
      "text_query" => request.query,
      "limit" => request.count |> max(1) |> min(@max_results),
      "enable_page_crawling" => false,
      "timeout_seconds" => @server_timeout_seconds
    }

    opts =
      KeyedHttp.request_opts(
        context,
        [
          {"content-type", "application/json"},
          {"accept", "application/json"},
          {"authorization", "Bearer " <> context.api_key}
        ] ++ LemonAi.Auth.KimiCodeOAuth.request_headers()
      )

    KeyedHttp.handle(
      "Kimi",
      context.http_post.(endpoint, [{:json, body} | opts]),
      fn decoded ->
        results =
          decoded
          |> Map.get("search_results")
          |> KeyedHttp.list()
          |> Enum.map(&map_item(&1, request))
          |> Enum.reject(&is_nil/1)
          |> Enum.take(request.count)

        {:ok, Result.search_results(request.query, id(), results, started_ms)}
      end
    )
  end

  defp map_item(%{"url" => url} = item, request) when is_binary(url) and url != "" do
    snippet = present(item["snippet"]) || present(item["content"])
    KeyedHttp.mapped(request, present(item["title"]) || url, url, snippet, present(item["date"]))
  end

  defp map_item(_item, _request), do: nil

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil
end
