defmodule CodingAgent.Tools.WebSearch do
  @moduledoc """
  WebSearch tool for the coding agent.

  Performs a lightweight web search and returns top results.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

  @default_max_results 5
  @max_results 10

  @doc """
  Returns the WebSearch tool definition.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(_cwd, _opts \\ []) do
    %AgentTool{
      name: "websearch",
      description: "Search the web and return top results.",
      label: "Web Search",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "Search query"
          },
          "max_results" => %{
            "type" => "integer",
            "description" => "Maximum number of results to return (max 10)"
          }
        },
        "required" => ["query"]
      },
      execute: &execute/4
    }
  end

  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      do_execute(params, signal)
    end
  end

  defp do_execute(params, signal) do
    query = Map.get(params, "query", "")
    max_results = Map.get(params, "max_results", @default_max_results) |> normalize_max_results()

    if query == "" do
      {:error, "Query is required"}
    else
      with :ok <- check_abort(signal),
           {:ok, response} <- fetch_results(query),
           :ok <- check_abort(signal) do
        results = extract_results(response)
        limited = Enum.take(results, max_results)

        output =
          case limited do
            [] ->
              "No results found."

            _ ->
              Enum.with_index(limited, 1)
              |> Enum.map(fn {result, idx} ->
                title = result.title || "(no title)"
                url = result.url || ""
                snippet = result.snippet || ""

                [
                  "#{idx}. #{title}",
                  url,
                  if(snippet != "", do: snippet, else: nil)
                ]
                |> Enum.reject(&is_nil/1)
                |> Enum.join("\n")
              end)
              |> Enum.join("\n\n")
          end

        %AgentToolResult{
          content: [%TextContent{text: output}],
          details: %{count: length(limited)}
        }
      end
    end
  end

  defp normalize_max_results(value) when is_integer(value) do
    value
    |> max(1)
    |> min(@max_results)
  end

  defp normalize_max_results(_), do: @default_max_results

  defp fetch_results(query) do
    params = [
      q: query,
      format: "json",
      no_redirect: 1,
      no_html: 1,
      skip_disambig: 1
    ]

    Req.get("https://api.duckduckgo.com/", params: params)
  end

  defp extract_results(%Req.Response{status: status, body: body}) when status in 200..299 do
    data = decode_json(body)
    results = get_list(data, "Results")
    related = get_list(data, "RelatedTopics")

    from_results = Enum.map(results, &map_result/1)
    from_related = extract_related(related)

    (from_results ++ from_related)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_results(_), do: []

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} -> data
      _ -> %{}
    end
  end

  defp decode_json(body) when is_map(body), do: body
  defp decode_json(_), do: %{}

  defp get_list(map, key) when is_map(map) do
    case Map.get(map, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp map_result(%{"Text" => text, "FirstURL" => url}) do
    {title, snippet} = split_text(text)
    %{title: title, url: url, snippet: snippet}
  end

  defp map_result(_), do: nil

  defp extract_related(list) do
    Enum.flat_map(list, fn
      %{"Text" => _text, "FirstURL" => _url} = item ->
        case map_result(item) do
          nil -> []
          result -> [result]
        end

      %{"Topics" => topics} when is_list(topics) ->
        extract_related(topics)

      _ ->
        []
    end)
  end

  defp split_text(text) do
    case String.split(text, " - ", parts: 2) do
      [title, snippet] -> {title, snippet}
      [title] -> {title, ""}
      _ -> {text, ""}
    end
  end

  defp check_abort(nil), do: :ok

  defp check_abort(signal) when is_reference(signal) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      :ok
    end
  end
end
