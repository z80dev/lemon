defmodule LemonMemory.SessionSearch do
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

      LemonMemory.SessionSearch.search("fix the login bug",
        scope: :session,
        scope_key: "agent:my_agent:main",
        limit: 5
      )
  """

  alias LemonMemory.Providers

  @default_limit 5
  @max_limit 20

  @doc """
  Search memory documents by free-text query.

  Returns a list of `LemonMemory.Document` structs, ordered by relevance.
  Returns `[]` when `session_search` is disabled or the query is blank.

  ## Options

  - `:scope` - `:session` (default), `:agent`, `:workspace`, `:all`
  - `:scope_key` - required for scope `:session`/`:agent`/`:workspace`
  - `:limit` - max results, capped at #{@max_limit} (default: #{@default_limit})
  """
  @spec search(binary(), keyword()) :: [LemonMemory.Document.t()]
  def search(query, opts \\ []) when is_binary(query) do
    cond do
      String.trim(query) == "" ->
        []

      not enabled?() ->
        []

      true ->
        limit = min(Keyword.get(opts, :limit, @default_limit), @max_limit)
        Providers.search(query, Keyword.put(opts, :limit, limit))
    end
  end

  @doc "Chronological owned run summaries around a document/run ID, or the latest window."
  def session(context, session, opts \\ []) when is_binary(session) and session != "" do
    with {:ok, rows} <- history(context, Keyword.put(opts, :session, session)) do
      {:ok,
       rows
       |> Enum.map(&elem(&1, 0))
       |> Enum.sort_by(&{&1.started_at_ms || &1.ingested_at_ms, &1.doc_id})
       |> bound_documents()}
    end
  end

  @doc "Recent owned sessions, represented by their first prompt and full run count."
  def recent_sessions(context, opts \\ []) do
    with {:ok, rows} <- history(context, opts) do
      {:ok,
       Enum.map(Enum.reverse(rows), fn {doc, count} ->
         %{
           session: doc.session_key,
           title: clip(doc.prompt_summary, 512),
           timestamp: doc.ingested_at_ms,
           run_count: count
         }
       end)}
    end
  end

  @doc "Render a bounded browse page as untrusted conversation data."
  def format_sessions(sessions) do
    sessions
    |> Enum.map_join("\n\n", fn item ->
      "session: #{item.session} | #{format_timestamp(item.timestamp)} | #{item.run_count} runs\n#{item.title}"
    end)
    |> clip(65_536)
  end

  defp history(context, opts) do
    with {:ok, identity} <- LemonMemory.Project.scope(context),
         {:ok, owner} <- LemonMemory.ContextScope.scope(context) do
      if enabled?() do
        window =
          case Keyword.get(opts, :window, 5) do
            n when is_integer(n) -> n |> max(1) |> min(20)
            _ -> 5
          end

        LemonMemory.Store.history_window(
          Keyword.get(opts, :store, LemonMemory.Store),
          identity.agent_id,
          identity.home_digest,
          owner,
          opts
          |> Keyword.put(:limit, window)
          |> Keyword.put(
            :workspace_root,
            if(Keyword.get(opts, :scope, :agent) in [:workspace, :project], do: identity.root)
          )
        )
      else
        {:ok, []}
      end
    end
  end

  defp bound_documents(docs) do
    Enum.map(docs, fn doc ->
      %{
        doc
        | prompt_summary: clip(doc.prompt_summary, 1024),
          answer_summary: clip(doc.answer_summary, 2048)
      }
    end)
  end

  defp clip(nil, _), do: ""

  defp clip(text, bytes) do
    text
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, acc ->
      if byte_size(acc) + byte_size(grapheme) <= bytes,
        do: {:cont, acc <> grapheme},
        else: {:halt, acc}
    end)
  end

  @doc """
  Same as `search/2` but returns results formatted as a human-readable string
  suitable for injection into an agent's context.
  """
  @spec format_results([LemonMemory.Document.t()]) :: String.t()
  def format_results([]), do: "No matching memory documents found."

  def format_results(docs) when is_list(docs) do
    docs
    |> Enum.with_index(1)
    |> Enum.map(fn {doc, idx} ->
      ts = format_timestamp(doc.ingested_at_ms)

      """
      [#{idx}] #{ts} | session: #{doc.session_key} | doc: #{doc.doc_id} | run: #{doc.run_id}
      Q: #{doc.prompt_summary}
      A: #{doc.answer_summary}
      """
      |> String.trim()
    end)
    |> Enum.join("\n\n")
    |> clip(65_536)
  end

  @doc "Whether local history search is enabled by the owning feature policy."
  def enabled? do
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
