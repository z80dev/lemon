defmodule CodingAgent.Search.Providers.DuckDuckGo do
  @moduledoc "Keyless DuckDuckGo HTML search provider."

  @behaviour CodingAgent.Search.Provider

  alias CodingAgent.Search.Result

  @endpoint "https://html.duckduckgo.com/html/"

  @impl true
  def id, do: "duckduckgo"

  @impl true
  def capabilities, do: [:search]

  @impl true
  def available?(:search, _context), do: :ok

  @impl true
  def search(request, context) do
    started_ms = System.monotonic_time(:millisecond)
    url = @endpoint <> "?" <> URI.encode_query(%{"q" => request.query})

    opts = [
      headers: [
        {"accept", "text/html,application/xhtml+xml"},
        {"user-agent", Map.get(context, :user_agent, "Lemon/1.0 websearch")}
      ],
      connect_options: [timeout: context.timeout_ms],
      receive_timeout: context.timeout_ms,
      redirect: true,
      max_redirects: 3
    ]

    case context.http_get.(url, opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        case Floki.parse_document(Result.to_string_safe(body)) do
          {:ok, document} ->
            results =
              document
              |> Floki.find(".result")
              |> Enum.map(&map_result(&1, request))
              |> Enum.reject(&is_nil/1)
              |> Enum.take(request.count)

            {:ok, Result.search_results(request.query, id(), results, started_ms)}

          {:error, reason} ->
            {:error, "DuckDuckGo response parse failed: #{inspect(reason)}"}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, "DuckDuckGo search error (#{status})"}

      {:error, reason} ->
        {:error, "DuckDuckGo search request failed: #{Result.format_reason(reason)}"}

      other ->
        {:error, "Unexpected DuckDuckGo search result: #{inspect(other)}"}
    end
  end

  defp map_result(node, request) do
    link = Floki.find(node, ".result__a") |> List.first()
    snippet = Floki.find(node, ".result__snippet") |> Floki.text(sep: " ")

    case link do
      nil ->
        nil

      link ->
        href = link |> Floki.attribute("href") |> List.first() |> unwrap_redirect()
        title = Floki.text(link, sep: " ")

        Result.mapped_result(title, href, snippet,
          title_max_chars: request.snippet_max_chars,
          description_max_chars: request.max_chars
        )
    end
  end

  defp unwrap_redirect(nil), do: nil

  defp unwrap_redirect(url) do
    uri = URI.parse(url)

    case URI.decode_query(uri.query || "") do
      %{"uddg" => target} -> target
      _ -> url
    end
  rescue
    _ -> url
  end
end
