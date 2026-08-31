defmodule CodingAgent.Search.Providers.Brave do
  @moduledoc "Brave Search API provider."

  @behaviour CodingAgent.Search.Provider

  alias CodingAgent.Search.Result

  @endpoint "https://api.search.brave.com/res/v1/web/search"

  @impl true
  def id, do: "brave"

  @impl true
  def capabilities, do: [:search]

  @impl true
  def available?(:search, %{api_key: key}) when is_binary(key) and key != "", do: :ok

  def available?(:search, _context) do
    {:error,
     %{
       "error" => "missing_brave_api_key",
       "message" =>
         "websearch (brave) needs an API key. Set BRAVE_API_KEY or configure agent.tools.web.search.api_key.",
       "docs" => "docs/tools/web.md"
     }}
  end

  @impl true
  def search(request, context) do
    started_ms = System.monotonic_time(:millisecond)

    params =
      [{"q", request.query}, {"count", Integer.to_string(request.count)}]
      |> maybe_put("country", Map.get(request, :country))
      |> maybe_put("search_lang", Map.get(request, :search_lang))
      |> maybe_put("ui_lang", Map.get(request, :ui_lang))
      |> maybe_put("freshness", Map.get(request, :freshness))

    url = @endpoint <> "?" <> URI.encode_query(params)

    opts = [
      headers: [{"accept", "application/json"}, {"x-subscription-token", context.api_key}],
      connect_options: [timeout: context.timeout_ms],
      receive_timeout: context.timeout_ms
    ]

    case context.http_get.(url, opts) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        results =
          response.body
          |> Result.decode_json()
          |> get_in(["web", "results"])
          |> case do
            values when is_list(values) -> values
            _ -> []
          end
          |> Enum.map(&map_result(&1, request))

        {:ok, Result.search_results(request.query, id(), results, started_ms)}

      {:ok, %Req.Response{status: status} = response} ->
        detail = response.body |> Result.to_string_safe() |> String.trim()
        {:error, "Brave Search API error (#{status}): #{empty_default(detail)}"}

      {:error, reason} ->
        {:error, "Brave Search request failed: #{Result.format_reason(reason)}"}

      other ->
        {:error, "Unexpected Brave Search result: #{inspect(other)}"}
    end
  end

  defp map_result(entry, request) when is_map(entry) do
    Result.mapped_result(
      Map.get(entry, "title"),
      Map.get(entry, "url"),
      Map.get(entry, "description"),
      title_max_chars: request.snippet_max_chars,
      description_max_chars: request.max_chars,
      published: Map.get(entry, "age")
    )
  end

  defp map_result(_, _request), do: nil

  defp maybe_put(params, _key, value) when value in [nil, ""], do: params
  defp maybe_put(params, key, value), do: params ++ [{key, value}]
  defp empty_default(""), do: "request failed"
  defp empty_default(value), do: value
end
