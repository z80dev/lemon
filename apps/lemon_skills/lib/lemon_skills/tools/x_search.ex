defmodule LemonSkills.Tools.XSearch do
  @moduledoc """
  Tool for agents to search recent public X posts.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

  @doc """
  Returns the X search tool definition.
  """
  @spec tool(keyword()) :: AgentTool.t()
  def tool(_opts \\ []) do
    %AgentTool{
      name: "x_search",
      description: """
      Search recent public posts on X (Twitter) using the configured X API bearer \
      token or OAuth credentials. This is read-only and does not post, reply, or \
      monitor an account.
      """,
      label: "Search X",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "X recent-search query, using X API search operators when needed."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of posts to fetch (default: 10, max: 100)."
          },
          "sort_order" => %{
            "type" => "string",
            "enum" => ["recency", "relevancy"],
            "description" => "Optional X API sort order."
          },
          "since_id" => %{
            "type" => "string",
            "description" => "Optional lower tweet id boundary."
          },
          "until_id" => %{
            "type" => "string",
            "description" => "Optional upper tweet id boundary."
          },
          "next_token" => %{
            "type" => "string",
            "description" => "Optional pagination token returned by a previous x_search call."
          }
        },
        "required" => ["query"]
      },
      execute: &execute(&1, &2, &3, &4)
    }
  end

  @doc """
  Execute the x_search tool.
  """
  @spec execute(String.t(), map(), reference() | nil, function() | nil) ::
          AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, _signal, _on_update) do
    with {:ok, query} <- normalize_query(Map.get(params, "query")),
         {:ok, opts} <- normalize_opts(params),
         :ok <- ensure_configured(),
         {:ok, response} <- LemonChannels.Adapters.XAPI.Client.search_recent(query, opts) do
      format_result(query, response)
    else
      {:error, :not_configured} ->
        return_not_configured()

      {:error, {:invalid_input, message}} ->
        return_error(message)

      {:error, {:api_error, status, body}} ->
        return_error("API error (HTTP #{status}): #{inspect(body)}")

      {:error, reason} ->
        return_error("Failed to search X: #{inspect(reason)}")
    end
  end

  defp normalize_query(nil), do: {:error, {:invalid_input, "Missing required parameter: query"}}

  defp normalize_query(query) when is_binary(query) do
    case String.trim(query) do
      "" -> {:error, {:invalid_input, "Parameter 'query' cannot be empty"}}
      value -> {:ok, value}
    end
  end

  defp normalize_query(_), do: {:error, {:invalid_input, "Parameter 'query' must be a string"}}

  defp normalize_opts(params) do
    with {:ok, limit} <- normalize_limit(Map.get(params, "limit", 10)),
         {:ok, sort_order} <- normalize_sort_order(Map.get(params, "sort_order")),
         {:ok, since_id} <- normalize_optional_string(Map.get(params, "since_id"), "since_id"),
         {:ok, until_id} <- normalize_optional_string(Map.get(params, "until_id"), "until_id"),
         {:ok, next_token} <-
           normalize_optional_string(Map.get(params, "next_token"), "next_token") do
      opts =
        [
          limit: limit,
          sort_order: sort_order,
          since_id: since_id,
          until_id: until_id,
          next_token: next_token
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      {:ok, opts}
    end
  end

  defp normalize_limit(nil), do: {:ok, 10}

  defp normalize_limit(limit) when is_integer(limit) and limit > 0 do
    {:ok, min(limit, 100)}
  end

  defp normalize_limit(limit) when is_integer(limit) do
    {:error, {:invalid_input, "Parameter 'limit' must be a positive integer"}}
  end

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {parsed, ""} -> normalize_limit(parsed)
      _ -> {:error, {:invalid_input, "Parameter 'limit' must be a positive integer"}}
    end
  end

  defp normalize_limit(_),
    do: {:error, {:invalid_input, "Parameter 'limit' must be a positive integer"}}

  defp normalize_sort_order(nil), do: {:ok, nil}

  defp normalize_sort_order(sort_order) when is_binary(sort_order) do
    case String.trim(sort_order) do
      "" -> {:ok, nil}
      value when value in ["recency", "relevancy"] -> {:ok, value}
      _ -> {:error, {:invalid_input, "Parameter 'sort_order' must be recency or relevancy"}}
    end
  end

  defp normalize_sort_order(_),
    do: {:error, {:invalid_input, "Parameter 'sort_order' must be recency or relevancy"}}

  defp normalize_optional_string(nil, _name), do: {:ok, nil}

  defp normalize_optional_string(value, _name) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_optional_string(_value, name),
    do: {:error, {:invalid_input, "Parameter '#{name}' must be a string"}}

  defp ensure_configured do
    if LemonChannels.Adapters.XAPI.search_configured?() do
      :ok
    else
      {:error, :not_configured}
    end
  end

  defp format_result(query, %{"data" => tweets} = response) when is_list(tweets) do
    users =
      case get_in(response, ["includes", "users"]) do
        users when is_list(users) -> Map.new(users, fn user -> {user["id"], user} end)
        _ -> %{}
      end

    results = Enum.map(tweets, &format_tweet(&1, users))
    meta = Map.get(response, "meta", %{})
    next_token = Map.get(meta, "next_token")
    result_count = Map.get(meta, "result_count", length(results))

    text = render_results(query, results, next_token)

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{
        query: query,
        results: results,
        count: length(results),
        result_count: result_count,
        next_token: next_token
      }
    }
  end

  defp format_result(query, %{"meta" => %{"result_count" => 0}}) do
    %AgentToolResult{
      content: [%TextContent{text: "No X posts found for #{inspect(query)}."}],
      details: %{query: query, results: [], count: 0, result_count: 0, next_token: nil}
    }
  end

  defp format_result(_query, other) do
    return_error("Unexpected response from X API: #{inspect(other)}")
  end

  defp format_tweet(tweet, users) do
    author = Map.get(users, tweet["author_id"], %{})
    username = author["username"] || tweet["author_id"] || "unknown"

    %{
      id: tweet["id"],
      text: tweet["text"],
      author_id: tweet["author_id"],
      author_username: username,
      author_name: author["name"],
      created_at: tweet["created_at"],
      url: "https://x.com/#{username}/status/#{tweet["id"]}",
      public_metrics: tweet["public_metrics"] || %{}
    }
  end

  defp render_results(query, results, next_token) do
    posts =
      Enum.map(results, fn result ->
        """
        @#{result.author_username}
        Tweet ID: #{result.id}
        URL: #{result.url}
        #{result.text}
        """
      end)

    pagination =
      if next_token do
        "\nNext token: #{next_token}"
      else
        ""
      end

    """
    Found #{length(results)} X post(s) for #{inspect(query)}:

    #{Enum.join(posts, "\n---\n")}#{pagination}
    """
  end

  defp return_not_configured do
    text = """
    X search is not configured.

    To enable read-only X search, set X_API_BEARER_TOKEN. OAuth posting
    credentials also work when already configured for X tools.
    """

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{error: :not_configured}
    }
  end

  defp return_error(message) do
    %AgentToolResult{
      content: [%TextContent{text: message}],
      details: %{error: message}
    }
  end
end
