defmodule CodingAgent.Session.ContextCheckpoint do
  @moduledoc """
  Branch-local model exploration checkpoints. Reservations are journal entries, so
  concurrent calls, resume and tree navigation use the same single-use state.
  Rewind is committed at turn end, after all sibling tool receipts are persisted.
  The provider projection performs the identical cut without relying on delivery
  timing between the loop and the session's event subscriber.
  """

  alias CodingAgent.Messages.BranchSummaryMessage
  alias CodingAgent.Session.{BranchState, Persistence, Rewind}
  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.SessionEntry
  alias LemonAgent.Agent

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
        Agent.replace_messages(
          state.agent,
          Persistence.restore_messages_from_session(manager)
        )

      BranchState.restore(state)
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
              Rewind.collapse_context(
                session,
                data.boundary,
                data.report,
                %{
                  context_rewind: true,
                  checkpoint_call_id: data.call_id,
                  rewind_call_id: rewind_id,
                  boundary: data.boundary,
                  goal: data.goal
                },
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

  @doc false
  def retained_context(session, rewind_id) do
    data =
      case active(session) do
        %{data: %{status: "pending", rewind_call_id: ^rewind_id} = data} ->
          data

        _ ->
          session
          |> SessionManager.get_branch()
          |> Enum.reverse()
          |> Enum.find(fn entry ->
            entry.type == :branch_summary and field(entry.details, :context_rewind) == true and
              field(entry.details, :rewind_call_id) == rewind_id
          end)
          |> case do
            nil -> nil
            entry -> %{boundary: field(entry.details, :boundary), report: entry.summary}
          end
      end

    if data && SessionManager.get_entry(session, data.boundary) do
      prefix =
        Persistence.restore_messages_from_session(%{
          session
          | leaf_id: data.boundary
        })

      report =
        if Map.get(data, :status) == "pending",
          do: summary(data.report),
          else: %BranchSummaryMessage{summary: data.report}

      {:ok, prefix ++ [report]}
    else
      {:error, :checkpoint_not_found}
    end
  end

  # Only the session owner supplies the retained prefix. Tool metadata can
  # identify a candidate receipt, never authorize a context rewrite by itself.
  def project(messages, nil), do: messages

  def project(messages, resolve) when is_function(resolve, 1) do
    if Enum.any?(messages, &success?(&1, :context_rewind)),
      do: project_reversed(Enum.reverse(messages), [], messages, resolve),
      else: messages
  end

  defp project_reversed([], _after, original, _resolve), do: original

  defp project_reversed([message | before], after_messages, original, resolve) do
    projection =
      if success?(message, :context_rewind),
        do: project_candidate(message, before, after_messages, resolve)

    case projection do
      {:ok, messages} -> messages
      _ -> project_reversed(before, [message | after_messages], original, resolve)
    end
  end

  defp project_candidate(message, before, after_messages, resolve) do
    {assistant, results} = current_batch_from_reversed(before)
    id = field(message, :tool_call_id)

    if rewind_call?(message, assistant) do
      case resolve.(id) do
        {:ok, prefix} ->
          {later_results, tail} =
            Enum.split_while(after_messages, &(field(&1, :role) in [:tool_result, "tool_result"]))

          {:ok, prefix ++ siblings(assistant, results ++ [message] ++ later_results, id) ++ tail}

        {:error, _} ->
          :skip
      end
    else
      :skip
    end
  end

  defp rewind_call?(message, assistant) do
    content = field(assistant, :content)
    id = field(message, :tool_call_id)
    outer_name = field(message, :tool_name)

    is_list(content) and
      Enum.any?(content, fn call ->
        field(call, :id) == id and
          case {outer_name, field(call, :name)} do
            {"rewind", "rewind"} ->
              true

            {"tool_invoke", "tool_invoke"} ->
              field(field(call, :arguments), :name) == "rewind"

            _ ->
              false
          end
      end)
  end

  defp current_batch_from_reversed(messages) do
    {results, rest} =
      Enum.split_while(messages, &(field(&1, :role) in [:tool_result, "tool_result"]))

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
