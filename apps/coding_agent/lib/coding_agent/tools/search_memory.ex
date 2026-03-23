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
  - `:workspace_dir` - current assistant-home scope key
  - `:search_fn` - test override for search execution
  - `:format_results_fn` - test override for result formatting
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    context = %{
      session_key: Keyword.get(opts, :session_key),
      agent_id: Keyword.get(opts, :agent_id),
      project_key: normalize_scope_key(cwd),
      home_key: normalize_scope_key(Keyword.get(opts, :workspace_dir)),
      search_fn: Keyword.get(opts, :search_fn, &SessionSearch.search/2),
      format_results_fn: Keyword.get(opts, :format_results_fn, &SessionSearch.format_results/1)
    }

    %AgentTool{
      name: "search_memory",
      description: """
      Search your prior run history for past work, decisions, and outcomes. \
      Use this before starting a task to recall relevant context from earlier sessions. \
      Scope controls: "current" searches both the active project root and the assistant home, \
      "project" searches the current project root only, "home" searches the assistant home only, \
      "session" searches the current session only, and "agent" searches all sessions for the \
      current agent. Returns summaries ordered by relevance.
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
            "enum" => ["session", "agent", "project", "home", "current", "workspace", "all"],
            "description" =>
              "Search scope. \"current\" (default): active project root plus assistant home. \"project\": active project root only. \"home\": assistant home only. \"session\": current session only. \"agent\": all sessions for this agent. \"workspace\": deprecated alias for \"current\". \"all\": entire store."
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
    scope = parse_scope(Map.get(params, "scope", "current"))
    limit = parse_limit(Map.get(params, "limit", 5))

    if query == "" do
      text_result("query must be a non-empty string")
    else
      case search_scope(query, scope, params, context, limit) do
        {:ok, docs, details} ->
          text = context.format_results_fn.(docs)

          text_result(
            text,
            Map.merge(%{count: length(docs), query: query, scope: scope}, details)
          )

        {:error, message, details} ->
          text_result(message, Map.merge(%{query: query, scope: scope}, details))
      end
    end
  rescue
    e ->
      text_result("search_memory error: #{Exception.message(e)}")
  end

  # ── Private ────────────────────────────────────────────────────────────────────

  defp parse_scope("session"), do: :session
  defp parse_scope("agent"), do: :agent
  defp parse_scope("project"), do: :project
  defp parse_scope("home"), do: :home
  defp parse_scope("current"), do: :current
  defp parse_scope("workspace"), do: :current
  defp parse_scope("all"), do: :all
  defp parse_scope(_), do: :current

  defp parse_limit(n) when is_integer(n) and n >= 1 and n <= 20, do: n
  defp parse_limit(_), do: 5

  defp search_scope(query, :all, _params, context, limit) do
    docs = context.search_fn.(query, scope: :all, scope_key: nil, limit: limit)
    {:ok, docs, %{resolved_scopes: [:all]}}
  end

  defp search_scope(query, scope, params, context, limit) when scope in [:session, :agent] do
    with {:ok, scope_key} <- resolve_scope_key(scope, params, context) do
      docs = context.search_fn.(query, scope: scope, scope_key: scope_key, limit: limit)
      {:ok, docs, %{resolved_scopes: [scope]}}
    else
      {:error, message} -> {:error, message, %{}}
    end
  end

  defp search_scope(query, :project, params, context, limit) do
    with {:ok, scope_key} <- resolve_scope_key(:project, params, context) do
      docs = search_directory_scope(context, query, scope_key, limit)
      {:ok, docs, %{resolved_scopes: [:project]}}
    else
      {:error, message} -> {:error, message, %{}}
    end
  end

  defp search_scope(query, :home, params, context, limit) do
    with {:ok, scope_key} <- resolve_scope_key(:home, params, context) do
      docs = search_directory_scope(context, query, scope_key, limit)
      {:ok, docs, %{resolved_scopes: [:home]}}
    else
      {:error, message} -> {:error, message, %{}}
    end
  end

  defp search_scope(query, :current, _params, context, limit) do
    project_key = context.project_key
    home_key = context.home_key

    keys =
      [
        {:project, project_key},
        {:home, home_key}
      ]
      |> Enum.filter(fn {_label, key} -> is_binary(key) and key != "" end)
      |> Enum.uniq_by(fn {_label, key} -> key end)

    case keys do
      [] ->
        {:error, scope_resolution_error(:current), %{}}

      [{label, key}] ->
        docs = search_directory_scope(context, query, key, limit)
        {:ok, docs, %{resolved_scopes: [label]}}

      [{left_label, left_key}, {right_label, right_key}] ->
        left_docs = search_directory_scope(context, query, left_key, limit)
        right_docs = search_directory_scope(context, query, right_key, limit)

        docs =
          [left_docs, right_docs]
          |> interleave_lists()
          |> dedupe_docs()
          |> Enum.take(limit)

        {:ok, docs, %{resolved_scopes: [left_label, right_label]}}
    end
  end

  defp resolve_scope_key(:session, params, context),
    do: pick_scope_key(Map.get(params, "scope_key"), context.session_key, :session)

  defp resolve_scope_key(:agent, params, context),
    do: pick_scope_key(Map.get(params, "scope_key"), context.agent_id, :agent)

  defp resolve_scope_key(:project, params, context),
    do: pick_scope_key(Map.get(params, "scope_key"), context.project_key, :project)

  defp resolve_scope_key(:home, params, context),
    do: pick_scope_key(Map.get(params, "scope_key"), context.home_key, :home)

  defp pick_scope_key(param_key, context_key, scope) do
    scope_key = normalize_scope_key(param_key) || normalize_scope_key(context_key)

    if is_binary(scope_key) do
      {:ok, scope_key}
    else
      {:error, scope_resolution_error(scope)}
    end
  end

  defp search_directory_scope(context, query, scope_key, limit) do
    context.search_fn.(query, scope: :workspace, scope_key: scope_key, limit: limit)
  end

  defp scope_resolution_error(:session),
    do: "search_memory scope 'session' requires a current session key"

  defp scope_resolution_error(:agent),
    do: "search_memory scope 'agent' requires a current agent context"

  defp scope_resolution_error(:project),
    do: "search_memory scope 'project' requires a current project root"

  defp scope_resolution_error(:home),
    do: "search_memory scope 'home' requires a current assistant home"

  defp scope_resolution_error(:current),
    do: "search_memory scope 'current' requires a current project root or assistant home"

  defp normalize_scope_key(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_scope_key(_), do: nil

  defp interleave_lists(lists) when is_list(lists) do
    do_interleave_lists(Enum.map(lists, &Enum.to_list/1), [])
  end

  defp do_interleave_lists(lists, acc) do
    case Enum.split_with(lists, &(&1 == [])) do
      {_empty, []} ->
        acc

      {_empty, active} ->
        {tails, values} =
          Enum.map_reduce(active, [], fn
            [head | tail], collected -> {tail, [head | collected]}
          end)

        do_interleave_lists(tails, acc ++ Enum.reverse(values))
    end
  end

  defp dedupe_docs(docs) do
    {docs, _seen} =
      Enum.reduce(docs, {[], MapSet.new()}, fn doc, {acc, seen} ->
        doc_id = Map.get(doc, :doc_id) || Map.get(doc, "doc_id") || inspect(doc)

        if MapSet.member?(seen, doc_id) do
          {acc, seen}
        else
          {[doc | acc], MapSet.put(seen, doc_id)}
        end
      end)

    Enum.reverse(docs)
  end

  defp text_result(text, details \\ %{}) do
    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: details
    }
  end
end
