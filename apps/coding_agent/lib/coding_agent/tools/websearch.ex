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
  @max_query_length 500
  @default_timeout_s 30
  @rate_limit_window_ms 1_000
  @rate_limit_max_requests 5
  @rate_limit_table :coding_agent_websearch_rate_limit

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
          },
          "timeout" => %{
            "type" => "integer",
            "description" => "Request timeout in seconds"
          },
          "region" => %{
            "type" => "string",
            "description" => "region code (e.g., us-en)"
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
    query =
      params
      |> Map.get("query", "")
      |> normalize_query()

    max_results = Map.get(params, "max_results", @default_max_results) |> normalize_max_results()

    with :ok <- validate_query(query),
         :ok <- validate_timeout(Map.get(params, "timeout", nil)),
         :ok <- enforce_rate_limit(),
         :ok <- check_abort(signal),
         {:ok, response} <- fetch_results(query, Map.get(params, "timeout"), Map.get(params, "region")),
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

  defp normalize_max_results(value) when is_integer(value) do
    value
    |> max(1)
    |> min(@max_results)
  end

  defp normalize_max_results(_), do: @default_max_results

  defp fetch_results(query, timeout, region) do
    if test_env?() do
      {:ok, %Req.Response{status: 200, body: %{"Results" => [], "RelatedTopics" => []}}}
    else
    params = [
      q: query,
      format: "json",
      no_redirect: 1,
      no_html: 1,
      skip_disambig: 1
    ]

    params =
      case region do
        value when is_binary(value) and value != "" -> Keyword.put(params, :kl, value)
        _ -> params
      end

      Req.get("https://api.duckduckgo.com/", params: params, receive_timeout: timeout_to_ms(timeout))
    end
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

  def reset_rate_limit do
    ensure_rate_limit_table()
    :ets.insert(@rate_limit_table, {:window, System.monotonic_time(:millisecond), 0})
    :ok
  end

  defp normalize_query(query) when is_binary(query), do: String.trim(query)
  defp normalize_query(_), do: ""

  defp validate_query(""), do: {:error, "Query is required"}

  defp validate_query(query) when is_binary(query) do
    if String.length(query) > @max_query_length do
      {:error, "Query is too long (max #{@max_query_length} characters)"}
    else
      :ok
    end
  end

  defp validate_timeout(nil), do: :ok

  defp validate_timeout(value) when is_integer(value) and value > 0, do: :ok

  defp validate_timeout(value) when is_integer(value),
    do: {:error, "timeout must be a positive integer"}

  defp validate_timeout(_),
    do: {:error, "timeout must be an integer"}

  defp timeout_to_ms(nil), do: @default_timeout_s * 1_000
  defp timeout_to_ms(value) when is_integer(value) and value > 0, do: value * 1_000
  defp timeout_to_ms(_), do: @default_timeout_s * 1_000

  defp enforce_rate_limit do
    ensure_rate_limit_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@rate_limit_table, :window) do
      [] ->
        :ets.insert(@rate_limit_table, {:window, now, 1})
        :ok

      [{:window, started_at, count}] ->
        if now - started_at > @rate_limit_window_ms do
          :ets.insert(@rate_limit_table, {:window, now, 1})
          :ok
        else
          if count < @rate_limit_max_requests do
            :ets.insert(@rate_limit_table, {:window, started_at, count + 1})
            :ok
          else
            {:error, "Rate limit exceeded. Please try again later."}
          end
        end
    end
  end

  defp ensure_rate_limit_table do
    case :ets.whereis(@rate_limit_table) do
      :undefined ->
        :ets.new(@rate_limit_table, [:named_table, :set, :public, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  defp test_env? do
    Code.ensure_loaded?(Mix) and Mix.env() == :test
  end
end
