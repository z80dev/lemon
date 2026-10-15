defmodule CodingAgent.Session.ContextCheckpoint do
  @moduledoc """
  Branch-local model exploration checkpoints. Reservations are journal entries, so
  concurrent calls, resume and tree navigation use the same single-use state.
  Rewind is committed at turn end, after all sibling tool receipts are persisted.
  The provider projection performs the identical cut without relying on delivery
  timing between the loop and the session's event subscriber.
  """

  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.SessionEntry
  alias CodingAgent.Messages.BranchSummaryMessage

  @marker "context_checkpoint"

  def request(session, "checkpoint", id, goal) do
    case active(session) do
      nil ->
        data = %{status: "creating", call_id: id, goal: goal}
        manager = SessionManager.append_entry(session, SessionEntry.custom(@marker, data))
        {:ok, %{context_checkpoint: true, checkpoint_call_id: id, goal: goal}, manager}

      _ ->
        {:error, "Checkpoint already active."}
    end
  end

  def request(session, "rewind", id, report) do
    checkpoint = active(session)

    cond do
      is_nil(checkpoint) ->
        {:error, "No active checkpoint. Create a checkpoint before calling rewind."}

      field(checkpoint.data, :status) == "pending" ->
        {:error, "Checkpoint already completed; continue from the retained report."}

      field(checkpoint.data, :status) == "creating" ->
        {:error, "Checkpoint is not ready until its tool turn completes."}

      String.trim(report) == "" ->
        {:error, "Report cannot be empty."}

      user_since?(session, checkpoint.id) ->
        {:error, "Cannot rewind across a new user message."}

      true ->
        data =
          Map.merge(checkpoint.data, %{
            status: "pending",
            rewind_call_id: id,
            report: String.trim(report)
          })

        manager = SessionManager.append_entry(session, SessionEntry.custom(@marker, data))

        {:ok,
         %{
           context_rewind: true,
           checkpoint_call_id: field(data, :call_id),
           report: String.trim(report)
         }, manager}
    end
  end

  def active(session) do
    session
    |> SessionManager.get_branch()
    |> Enum.reverse()
    |> Enum.find(fn entry ->
      entry.custom_type == @marker or
        (entry.type == :branch_summary and field(entry.details, :context_rewind) == true)
    end)
    |> case do
      %{custom_type: @marker, data: data} = entry ->
        if field(data, :status) == "cancelled",
          do: nil,
          else: %{entry | data: normalize_data(data)}

      _ ->
        nil
    end
  end

  def finish_turn(state, assistant, results) do
    {manager, rewound} = complete_turn(state.session_manager, assistant, results)
    state = %{state | session_manager: manager}

    if rewound do
      :ok =
        LemonAgent.Agent.replace_messages(
          state.agent,
          CodingAgent.Session.Persistence.restore_messages_from_session(manager)
        )

      CodingAgent.Session.BranchState.restore(state)
    else
      state
    end
  end

  @doc false
  def complete_turn(session, assistant, results) do
    case active(session) do
      %{data: data} ->
        rewind_id = field(data, :rewind_call_id)

        cond do
          data.status == "pending" and
              Enum.any?(
                results,
                &(success?(&1, :context_rewind) and field(&1, :tool_call_id) == rewind_id)
              ) ->
            retained = siblings(assistant, results, rewind_id)

            {:ok, manager} =
              CodingAgent.Session.Rewind.collapse_context(
                session,
                data.boundary,
                data.report,
                %{context_rewind: true, checkpoint_call_id: data.call_id, goal: data.goal},
                retained
              )

            {manager, true}

          data.status == "creating" and
              Enum.any?(results, &(field(&1, :tool_call_id) == data.call_id)) ->
            status =
              if Enum.any?(
                   results,
                   &(success?(&1, :context_checkpoint) and
                       field(&1, :tool_call_id) == data.call_id)
                 ), do: "active", else: "cancelled"

            ready = data |> Map.put(:status, status) |> Map.put(:boundary, session.leaf_id)
            {SessionManager.append_entry(session, SessionEntry.custom(@marker, ready)), false}

          data.status == "pending" and
              Enum.any?(results, &(field(&1, :tool_call_id) == rewind_id)) ->
            restored =
              data
              |> Map.put(:status, "active")
              |> Map.delete(:rewind_call_id)
              |> Map.delete(:report)

            {SessionManager.append_entry(session, SessionEntry.custom(@marker, restored)), false}

          true ->
            {session, false}
        end

      _ ->
        {session, false}
    end
  end

  # Project from authenticated tool receipts rather than names. A tool_invoke
  # bridge keeps those receipts and the outer call ID unchanged.
  def project(messages) do
    if Enum.any?(messages, &success?(&1, :context_rewind)) do
      messages
      |> Enum.reduce([], fn message, reversed ->
        if success?(message, :context_rewind) do
          acc = Enum.reverse(reversed)
          details = field(message, :details)
          checkpoint_id = field(details, :checkpoint_call_id)
          {before, suffix} = Enum.split_while(acc, &(not checkpoint_result?(&1, checkpoint_id)))

          case suffix do
            [] ->
              [message | reversed]

            [checkpoint | after_checkpoint] ->
              {batch, _exploration} =
                Enum.split_while(
                  after_checkpoint,
                  &(field(&1, :role) in [:tool_result, "tool_result"])
                )

              {assistant, results} = current_batch(acc)
              retained = siblings(assistant, results ++ [message], field(message, :tool_call_id))

              Enum.reverse(
                before ++ [checkpoint] ++ batch ++ [summary(field(details, :report))] ++ retained
              )
          end
        else
          [message | reversed]
        end
      end)
      |> Enum.reverse()
    else
      messages
    end
  end

  defp checkpoint_result?(message, id),
    do: success?(message, :context_checkpoint) and field(message, :tool_call_id) == id

  defp current_batch(messages) do
    {results, rest} =
      messages
      |> Enum.reverse()
      |> Enum.split_while(&(field(&1, :role) in [:tool_result, "tool_result"]))

    {List.first(rest), Enum.reverse(results)}
  end

  defp siblings(nil, _results, _rewind_id), do: []

  defp siblings(assistant, results, rewind_id) do
    content = field(assistant, :content) || []

    calls =
      Enum.filter(
        content,
        &(field(&1, :type) in [:tool_call, "tool_call"] and field(&1, :id) != rewind_id)
      )

    ids = MapSet.new(calls, &field(&1, :id))
    results = Enum.filter(results, &MapSet.member?(ids, field(&1, :tool_call_id)))
    if calls == [], do: [], else: [put_content(assistant, calls) | results]
  end

  defp put_content(%{content: _} = message, content), do: %{message | content: content}
  defp put_content(message, content), do: Map.put(message, "content", content)

  defp summary(report),
    do: %BranchSummaryMessage{
      summary:
        "Checkpoint complete. Continue from these findings; do not rewind again.\n\n" <> report
    }

  defp success?(message, kind),
    do: field(field(message, :details), kind) == true and field(message, :is_error) != true

  defp user_since?(session, id) do
    session
    |> SessionManager.get_branch()
    |> Enum.drop_while(&(&1.id != id))
    |> Enum.any?(&(field(&1.message, :role) in [:user, "user"]))
  end

  defp normalize_data(data) do
    Map.new(
      [:status, :call_id, :goal, :boundary, :rewind_call_id, :report],
      &{&1, field(data, &1)}
    )
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_, _), do: nil
end
