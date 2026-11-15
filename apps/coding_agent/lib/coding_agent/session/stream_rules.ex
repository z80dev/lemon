defmodule CodingAgent.Session.StreamRules do
  @moduledoc """
  Session-owned stream-rule injection receipts.

  Limits are lifetime counts by rule name across the entire journal, including
  abandoned branches. Compaction and navigation therefore cannot replenish them.
  The receipt is appended and synced before the correction is queued. A crash in
  between may consume an injection, but can never replay one after recovery.
  """

  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.SessionEntry

  @entry_type "lemon.stream_rule"

  @doc false
  def available(manager, rules) do
    counts =
      Enum.reduce(manager.entries_rev, %{}, fn
        %SessionEntry{type: :custom, custom_type: @entry_type, data: %{"name" => name}}, acc ->
          Map.update(acc, name, 1, &(&1 + 1))

        _, acc ->
          acc
      end)

    Enum.filter(rules, &(Map.get(counts, &1.name, 0) < &1.injection_limit))
  end

  @doc false
  def inject(state, rule) do
    count =
      Enum.count(state.session_manager.entries_rev, fn
        %SessionEntry{type: :custom, custom_type: @entry_type, data: data} ->
          data["name"] == rule.name

        _ ->
          false
      end)

    if count < rule.injection_limit do
      record_and_redirect(state, rule)
    else
      {:error, :injection_limit, state}
    end
  end

  defp record_and_redirect(state, rule) do
    entry = SessionEntry.custom(@entry_type, %{"version" => 1, "name" => rule.name})
    manager = SessionManager.append_entry(state.session_manager, entry)
    state = %{state | session_manager: manager}

    case SessionManager.checkpoint(manager) do
      :ok ->
        message = %LemonAi.Types.UserMessage{
          role: :user,
          content:
            "<system-interrupt reason=\"rule_violation\">\n" <>
              rule.content <> "\n</system-interrupt>",
          timestamp: System.system_time(:millisecond)
        }

        :ok = LemonAgent.Agent.redirect(state.agent, message)
        {:ok, %{state | steering_queue: :queue.in(message, state.steering_queue)}}

      {:error, reason} ->
        {:error, {:journal_sync_failed, reason}, state}
    end
  end
end
