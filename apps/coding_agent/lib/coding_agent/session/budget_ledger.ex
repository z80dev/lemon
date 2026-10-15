defmodule CodingAgent.Session.BudgetLedger do
  @moduledoc """
  Cumulative provider spend, independent of the selected transcript branch.

  Snapshots include reported interrupted/retried requests, not just visible
  assistant messages. Legacy files derive their initial spend from all stored
  assistant messages. Forks and clear inherit the ledger; rewinds and compaction
  never subtract from it.
  """

  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.SessionEntry
  alias LemonAgent.Budget

  @custom_type "lemon.budget_usage"

  @spec restore(SessionManager.Session.t()) :: map()
  def restore(session) do
    entries = SessionManager.entries(session)

    case Enum.find(
           Enum.reverse(entries),
           &(&1.type == :custom and &1.custom_type == @custom_type)
         ) do
      nil ->
        Enum.reduce(entries, Budget.normalize_usage(nil), fn
          %SessionEntry{type: :message, message: message}, usage ->
            Budget.add_usage(usage, Budget.usage_from_message(message))

          _, usage ->
            usage
        end)

      entry ->
        Budget.normalize_usage(entry.data)
    end
  end

  @spec initialize(SessionManager.Session.t()) :: {SessionManager.Session.t(), map()}
  def initialize(session) do
    usage = restore(session)

    if Enum.any?(
         SessionManager.entries(session),
         &(&1.type == :custom and &1.custom_type == @custom_type)
       ) do
      {session, usage}
    else
      {append(session, usage), usage}
    end
  end

  @spec append(SessionManager.Session.t(), map()) :: SessionManager.Session.t()
  def append(session, usage) do
    SessionManager.append_entry(
      session,
      SessionEntry.custom(@custom_type, Budget.normalize_usage(usage))
    )
  end

  @doc "Restore enforcement-only descendant spend, never provider usage."
  def restore_children(session) do
    session
    |> SessionManager.entries()
    |> Enum.reverse()
    |> Enum.find_value(Budget.normalize_usage(nil), fn
      %SessionEntry{type: :custom, custom_type: "lemon.subagent_budget_usage", data: usage} ->
        Budget.normalize_usage(usage)

      _ ->
        nil
    end)
  end

  def append_children(session, usage) do
    SessionManager.append_entry(
      session,
      SessionEntry.custom("lemon.subagent_budget_usage", Budget.normalize_usage(usage))
    )
  end

  @spec update(map(), map()) :: map()
  def update(state, %{session_usage: usage}) do
    usage = Budget.normalize_usage(usage)
    previous = Budget.normalize_usage(Map.get(state, :budget_usage))

    usage = %{
      tokens: max(previous.tokens, usage.tokens),
      cost_usd: max(previous.cost_usd, usage.cost_usd)
    }

    if usage == Map.get(state, :budget_usage) do
      state
    else
      state
      |> Map.put(:budget_usage, usage)
      |> Map.put(:session_manager, append(state.session_manager, usage))
    end
  end
end
