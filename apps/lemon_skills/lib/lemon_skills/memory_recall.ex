defmodule LemonSkills.MemoryRecall do
  @moduledoc """
  Automatic memory recall: the `LemonAgent.ContextRegistry` contributor that
  puts a bounded "Relevant memory" block into each main-session turn.

  Registered by `LemonSkills.Application` under `:memory_recall`, through the
  same seam `LemonHoncho.ContextContributor` uses. For each turn it asks
  `LemonMemory.Recall.block/2` for authorized earlier conversations and canonical
  preferences, plus bounded project learnings from `LemonMemory.Project.read/2`.
  Context-owned runs require verified native ownership and never read raw legacy
  preference files; legacy unscoped CLI behavior remains unchanged. Project defaults
  need not match the opening query; the result is one `:user_message` section.
  The block changes every
  turn, so it rides after the last prompt-cache breakpoint (attached to the
  outgoing message by `CodingAgent.Session.attach_recalled_context/2`) instead
  of invalidating the cached system prompt.

  It skips — returning `:skip`, which costs the turn nothing — when:

    * the session is a subagent (delegated tasks carry their own context);
    * `[memory] auto_recall = false`, or durable memory is switched off with
      `[features] session_search = "off"` (both read from the cached config,
      `LemonCore.Config.cached/1`, for the request's `:cwd`);
    * the request has no agent (`:agent_id`, or the agent segment of an
      `"agent:<id>:..."` session key);
    * the message is trivially short or nothing relevant is stored.

  The work is one local SQLite query and string handling — no model call, no
  network — which is what lets it run inside the registry's default 250 ms
  budget on the turn path.
  """

  @behaviour LemonAgent.ContextRegistry

  alias LemonMemory.{ContextScope, Project, Query, Recall}

  @impl true
  def contribute(request), do: contribute(request, [])

  @doc """
  `contribute/1` with overrides, for tests and embedders.

  ## Options

    * `:auto_recall` - use this instead of reading the config
    * `:store` - the `LemonMemory.Store` server to search
    * any other `LemonMemory.Recall.block/2` option (`:limit`, `:max_bytes`)
  """
  @spec contribute(term(), keyword()) :: {:ok, LemonAgent.ContextRegistry.section_spec()} | :skip
  def contribute(%{} = request, opts) when is_list(opts) do
    with :main <- Map.get(request, :session_scope),
         true <- auto_recall?(request, opts),
         {:ok, _memory_scope} <- ContextScope.scope(request),
         agent_id when is_binary(agent_id) <- agent_id(request),
         true <- length(Query.terms(Map.get(request, :query))) >= 2 do
      context = Map.put(request, :agent_id, agent_id)

      facts =
        case Project.read(context, Keyword.take(opts, [:store])) do
          {:ok, facts} -> facts
          {:error, _} -> []
        end

      case Recall.block(
             Map.get(request, :query),
             opts
             |> Keyword.delete(:auto_recall)
             |> Keyword.put(:agent_id, agent_id)
             |> Keyword.put(:workspace_dir, Map.get(request, :workspace_dir))
             |> Keyword.put(:context, context)
             |> Keyword.put(:project_facts, facts)
           ) do
        {:ok, body} -> {:ok, %{title: Recall.title(), body: body, placement: :user_message}}
        :skip -> :skip
      end
    else
      _ -> :skip
    end
  end

  def contribute(_request, _opts), do: :skip

  # An unreadable config turns recall off for the turn rather than failing it.
  defp auto_recall?(request, opts) do
    case LemonCore.Config.cached(Map.get(request, :cwd)) do
      %LemonCore.Config{memory: %{auto_recall: configured}} ->
        configured and Keyword.get(opts, :auto_recall, true) == true

      _ ->
        false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp agent_id(request) do
    case Map.get(request, :agent_id) do
      agent_id when is_binary(agent_id) and agent_id != "" -> agent_id
      _ -> agent_from_session_key(Map.get(request, :session_key))
    end
  end

  defp agent_from_session_key("agent:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [agent_id | _] when agent_id != "" -> agent_id
      _ -> nil
    end
  end

  defp agent_from_session_key(_session_key), do: nil
end
