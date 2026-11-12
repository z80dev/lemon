defmodule CodingAgent.Session.ContextBudget do
  @moduledoc """
  Current request context, not cumulative run spending. Uses exactly the same
  estimator and reserve threshold as automatic compaction. Headroom is the
  remaining token budget before that threshold, not the model's output limit.
  An unknown model window leaves capacity fields `nil` and disables token-based
  automatic compaction while still reporting the estimated/measured token usage.
  """

  alias CodingAgent.Compaction
  alias CodingAgent.Session.{CompactionManager, Planning}

  def measure(state, agent_state, messages \\ nil) do
    settings = CompactionManager.get_compaction_settings(state.settings_manager)
    window = state.model.context_window
    threshold = Compaction.context_threshold(window, settings)
    usage_after = usage_boundary(state.session_manager)

    usage =
      Compaction.request_context_usage(
        messages || agent_state.messages || [],
        agent_state.system_prompt,
        agent_state.tools || [],
        usage_after
      )

    Map.merge(usage, %{
      window: if(threshold, do: window),
      reserve_tokens: if(threshold, do: window - threshold),
      threshold_tokens: threshold,
      headroom_tokens: if(threshold, do: max(threshold - usage.tokens, 0)),
      enabled: not is_nil(threshold) and Map.get(settings, :enabled, true),
      usage_after: usage_after
    })
  end

  @doc """
  Timestamp of the newest compaction or planning boundary on the active branch;
  provider usage recorded before it no longer describes the current context.
  """
  def usage_boundary(%{by_id: entries, leaf_id: leaf}), do: usage_boundary(entries, leaf)
  def usage_boundary(_), do: nil
  defp usage_boundary(_entries, nil), do: nil

  defp usage_boundary(entries, id) do
    case Map.get(entries, id) do
      nil ->
        nil

      entry ->
        if entry.type == :compaction or Planning.context_boundary?(entry),
          do: entry.timestamp,
          else: usage_boundary(entries, entry.parent_id)
    end
  end
end
