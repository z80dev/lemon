defmodule CodingAgent.Tools.SearchMemory do
  @moduledoc """
  Tool for searching prior run memory.

  Queries the durable memory store (M5) for past run summaries matching the
  given text. Results are scoped by session, agent, or workspace.

  Requires the `session_search` feature flag to be enabled; returns a
  "not available" message when the flag is off.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias LemonCore.SessionSearch

  @doc """
  Returns the SearchMemory tool definition.

  ## Options

  - `:session_key` - current session scope key
  - `:agent_id` - current agent scope key
  - `:workspace_dir` - current workspace scope key
  - `:search_fn` - test override for search execution
  - `:format_results_fn` - test override for result formatting
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    context = %{
      session_key: Keyword.get(opts, :session_key),
      agent_id: Keyword.get(opts, :agent_id),
      workspace_key: Keyword.get(opts, :workspace_dir) || Keyword.get(opts, :cwd),
      search_fn: Keyword.get(opts, :search_fn, &SessionSearch.search/2),
      format_results_fn: Keyword.get(opts, :format_results_fn, &SessionSearch.format_results/1)
    }

    %AgentTool{
      name: "search_memory",
      description: """
      Search your prior run history for past work, decisions, and outcomes. \
      Use this before starting a task to recall relevant context from earlier sessions. \
      Scope controls: "session" searches the current session only, "agent" searches \
      all sessions for the current agent, "workspace" searches all sessions for this \
      directory. Returns summaries ordered by relevance.
      """,
      label: "Search Memory",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "Free-text search query (e.g. \"fix login bug\", \"deploy steps\")"
          },
          "scope" => %{
            "type" => "string",
            "enum" => ["session", "agent", "workspace", "all"],
            "description" =>
              "Search scope. \"session\" (default): current session only. \"agent\": all sessions for this agent. \"workspace\": all sessions for this directory. \"all\": entire store."
          },
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 20,
            "description" => "Maximum number of results to return (default: 5)."
          }
        },
        "required" => ["query"]
      },
      execute: &execute(&1, &2, &3, &4, context)
    }
  end

  @spec execute(
          String.t(),
          map(),
          reference() | nil,
          (AgentToolResult.t() -> :ok) | nil,
          map()
        ) :: AgentToolResult.t()
  def execute(_tool_call_id, params, _signal, _on_update, context) do
    query = Map.get(params, "query", "") |> to_string() |> String.trim()
    scope = parse_scope(Map.get(params, "scope", "session"))
    limit = parse_limit(Map.get(params, "limit", 5))

    if query == "" do
      text_result("query must be a non-empty string")
    else
      scope_key = resolve_scope_key(scope, params, context)

      cond do
        scope != :all and is_nil(scope_key) ->
          text_result(scope_resolution_error(scope), %{query: query, scope: scope})

        true ->
          search_opts = [scope: scope, scope_key: scope_key, limit: limit]
          docs = context.search_fn.(query, search_opts)
          text = context.format_results_fn.(docs)
          text_result(text, %{count: length(docs), query: query, scope: scope})
      end
    end
  rescue
    e ->
      text_result("search_memory error: #{Exception.message(e)}")
  end

  # ── Private ────────────────────────────────────────────────────────────────────

  defp parse_scope("agent"), do: :agent
  defp parse_scope("workspace"), do: :workspace
  defp parse_scope("all"), do: :all
  defp parse_scope(_), do: :session

  defp parse_limit(n) when is_integer(n) and n >= 1 and n <= 20, do: n
  defp parse_limit(_), do: 5

  defp resolve_scope_key(:session, params, context) do
    Map.get(params, "scope_key") || context.session_key
  end

  defp resolve_scope_key(:agent, params, context) do
    Map.get(params, "scope_key") || context.agent_id
  end

  defp resolve_scope_key(:workspace, params, context) do
    Map.get(params, "scope_key") || context.workspace_key
  end

  defp resolve_scope_key(:all, _params, _context), do: nil

  defp scope_resolution_error(:session),
    do: "search_memory scope 'session' requires a current session key"

  defp scope_resolution_error(:agent),
    do: "search_memory scope 'agent' requires a current agent context"

  defp scope_resolution_error(:workspace),
    do: "search_memory scope 'workspace' requires a current workspace context"

  defp text_result(text, details \\ %{}) do
    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: details
    }
  end
end
