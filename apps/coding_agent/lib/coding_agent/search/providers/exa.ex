defmodule CodingAgent.Search.Providers.Exa do
  @moduledoc "Exa semantic search and readable-content extraction provider."

  @behaviour CodingAgent.Search.Provider

  alias CodingAgent.Search.Result

  @default_base_url "https://api.exa.ai"

  @impl true
  def id, do: "exa"

  @impl true
  def capabilities, do: [:search, :extract]

  @impl true
  def available?(capability, %{api_key: key})
      when capability in [:search, :extract] and is_binary(key) and key != "",
      do: :ok

  def available?(capability, _context) when capability in [:search, :extract] do
    {:error,
     %{
       "error" => "missing_exa_api_key",
       "message" =>
         "#{tool_name(capability)} (exa) needs an API key. Set EXA_API_KEY or configure runtime.tools.web.#{config_section(capability)}.providers.exa.api_key.",
       "docs" => "docs/tools/web.md"
     }}
  end

  @impl true
  def search(request, context) do
    started_ms = System.monotonic_time(:millisecond)

    body = %{
      "query" => request.query,
      "type" => Map.get(request, :search_type, "auto"),
      "numResults" => request.count,
      "contents" => %{
        "highlights" => %{
          "query" => request.query,
          "maxCharacters" => request.max_chars
        }
      }
    }

    case post(context, "/search", body) do
      {:ok, decoded} ->
        results =
          decoded
          |> Map.get("results", [])
          |> Enum.map(&map_search_result(&1, request))

        {:ok, Result.search_results(request.query, id(), results, started_ms)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def extract(request, context) do
    started_ms = System.monotonic_time(:millisecond)

    body = %{
      "urls" => [request.url],
      "text" => %{"maxCharacters" => request.max_chars}
    }

    case post(context, "/contents", body) do
      {:ok, %{"results" => [result | _]}} when is_map(result) ->
        text = result |> Map.get("text", "") |> Result.to_string_safe()
        wrapped = Result.wrap_fetch_content(text, request.max_chars)
        title = Result.wrap_fetch_field(Map.get(result, "title"))

        {:ok,
         %{
           "url" => request.url,
           "finalUrl" => Map.get(result, "url") || request.url,
           "status" => 200,
           "contentType" => "text/markdown",
           "title" => title,
           "extractMode" => Atom.to_string(request.extract_mode),
           "extractor" => "exa",
           "truncated" => wrapped.truncated,
           "length" => wrapped.wrapped_length,
           "rawLength" => wrapped.raw_length,
           "wrappedLength" => wrapped.wrapped_length,
           "fetchedAt" => DateTime.utc_now() |> DateTime.to_iso8601(),
           "tookMs" => max(System.monotonic_time(:millisecond) - started_ms, 0),
           "text" => wrapped.text,
           "trustMetadata" => Result.fetch_trust_metadata(wrapped, title)
         }}

      {:ok, decoded} ->
        {:error, "Exa Contents API returned no content: #{safe_detail(decoded)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp post(context, path, body) do
    url = base_url(context) <> path

    opts = [
      headers: [
        {"accept", "application/json"},
        {"content-type", "application/json"},
        {"x-api-key", context.api_key},
        {"x-exa-integration", "lemon"}
      ],
      json: body,
      connect_options: [timeout: context.timeout_ms],
      receive_timeout: context.timeout_ms
    ]

    case context.http_post.(url, opts) do
      {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
        {:ok, Result.decode_json(response_body)}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, "Exa API error (#{status}): #{safe_detail(response_body)}"}

      {:error, reason} ->
        {:error, "Exa API request failed: #{Result.format_reason(reason)}"}

      other ->
        {:error, "Unexpected Exa API result: #{inspect(other)}"}
    end
  end

  defp map_search_result(entry, request) when is_map(entry) do
    description =
      entry
      |> Map.get("highlights", [])
      |> List.wrap()
      |> Enum.map(&Result.to_string_safe/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    Result.mapped_result(
      Map.get(entry, "title"),
      Map.get(entry, "url") || Map.get(entry, "id"),
      description,
      title_max_chars: request.snippet_max_chars,
      description_max_chars: request.max_chars,
      published: Map.get(entry, "publishedDate")
    )
  end

  defp map_search_result(_, _request), do: nil

  defp base_url(context) do
    context
    |> Map.get(:base_url, @default_base_url)
    |> Result.to_string_safe()
    |> String.trim()
    |> String.trim_trailing("/")
    |> case do
      "" -> @default_base_url
      value -> value
    end
  end

  defp safe_detail(value) do
    value
    |> Result.to_string_safe()
    |> String.trim()
    |> case do
      "" -> "request failed"
      detail -> String.slice(detail, 0, 400)
    end
  end

  defp tool_name(:search), do: "websearch"
  defp tool_name(:extract), do: "webfetch"
  defp config_section(:search), do: "search"
  defp config_section(:extract), do: "fetch"
end
