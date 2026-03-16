defmodule LemonCore.SessionSearch do
  @moduledoc """
  Public search API over durable memory documents.

  All calls are feature-flagged behind `session_search`. Returns `[]` when
  the flag is off so callers never need to check.

  ## Scope controls

  | scope       | scope_key required? | Searches by          |
  |-------------|---------------------|----------------------|
  | `:session`  | yes                 | session_key          |
  | `:agent`    | yes                 | agent_id             |
  | `:workspace`| yes                 | workspace_key        |
  | `:all`      | no                  | all stored documents |

  ## Example

      LemonCore.SessionSearch.search("fix the login bug",
        scope: :session,
        scope_key: "agent:my_agent:main",
        limit: 5
      )
  """

  alias LemonCore.MemoryStore

  @default_limit 5
  @max_limit 20

  @doc """
  Search memory documents by free-text query.

  Returns a list of `LemonCore.MemoryDocument` structs, ordered by relevance.
  Returns `[]` when `session_search` is disabled or the query is blank.

  ## Options

  - `:scope` - `:session` (default), `:agent`, `:workspace`, `:all`
  - `:scope_key` - required for scope `:session`/`:agent`/`:workspace`
  - `:limit` - max results, capped at #{@max_limit} (default: #{@default_limit})
  """
  @spec search(binary(), keyword()) :: [LemonCore.MemoryDocument.t()]
  def search(query, opts \\ []) when is_binary(query) do
    cond do
      String.trim(query) == "" ->
        []

      not session_search_enabled?() ->
        []

      true ->
        limit = min(Keyword.get(opts, :limit, @default_limit), @max_limit)
        MemoryStore.search(query, Keyword.put(opts, :limit, limit))
    end
  end

  @doc """
  Same as `search/2` but returns results formatted as a human-readable string
  suitable for injection into an agent's context.
  """
  @spec format_results([LemonCore.MemoryDocument.t()]) :: String.t()
  def format_results([]), do: "No matching memory documents found."

  def format_results(docs) when is_list(docs) do
    docs
    |> Enum.with_index(1)
    |> Enum.map(fn {doc, idx} ->
      ts = format_timestamp(doc.ingested_at_ms)

      """
      [#{idx}] #{ts} | session: #{doc.session_key}
      Q: #{doc.prompt_summary}
      A: #{doc.answer_summary}
      """
      |> String.trim()
    end)
    |> Enum.join("\n\n")
  end

  # ── Private ────────────────────────────────────────────────────────────────────

  defp session_search_enabled? do
    config = LemonCore.Config.Modular.load()
    LemonCore.Config.Features.enabled?(config.features, :session_search)
  rescue
    _ -> false
  end

  defp format_timestamp(nil), do: "unknown"

  defp format_timestamp(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
  rescue
    _ -> "unknown"
  end
end
