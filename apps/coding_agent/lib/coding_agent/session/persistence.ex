defmodule CodingAgent.Session.Persistence do
  @moduledoc false

  require Logger

  alias AgentCore.Loop.TranscriptValidator
  alias CodingAgent.Session.MessageSerialization
  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.Session

  @spec persist_message(map(), term()) :: map()
  def persist_message(state, message) do
    new_session_manager =
      case message do
        %Ai.Types.UserMessage{} ->
          SessionManager.append_message(
            state.session_manager,
            MessageSerialization.serialize_message(message)
          )

        %Ai.Types.AssistantMessage{} ->
          SessionManager.append_message(
            state.session_manager,
            MessageSerialization.serialize_message(message)
          )

        %Ai.Types.ToolResultMessage{} ->
          SessionManager.append_message(
            state.session_manager,
            MessageSerialization.serialize_message(message)
          )

        %CodingAgent.Messages.CustomMessage{} ->
          append_custom_message_once(state.session_manager, message)

        _ ->
          state.session_manager
      end

    %{state | session_manager: new_session_manager}
  end

  @spec restore_messages_from_session(Session.t()) :: [map()]
  def restore_messages_from_session(session) do
    context = SessionManager.build_session_context(session)

    context.messages
    |> Enum.map(&MessageSerialization.deserialize_message/1)
    |> Enum.reject(&is_nil/1)
    |> restore_valid_tool_transcript(session)
  end

  @spec maybe_register_session(Session.t(), String.t(), boolean(), atom()) :: :ok
  def maybe_register_session(_session_manager, _cwd, false, _registry), do: :ok

  def maybe_register_session(session_manager, cwd, true, registry) do
    if Process.whereis(registry) do
      case Registry.register(registry, session_manager.header.id, %{cwd: cwd}) do
        {:ok, _} ->
          :ok

        {:error, {:already_registered, _pid}} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to register session: #{inspect(reason)}")
      end
    end
  end

  @spec maybe_unregister_session(String.t(), boolean(), atom()) :: :ok
  def maybe_unregister_session(_session_id, false, _registry), do: :ok

  def maybe_unregister_session(session_id, true, registry) do
    if Process.whereis(registry) do
      Registry.unregister(registry, session_id)
    end

    :ok
  end

  @spec save(map()) :: {:ok, map()} | {:error, term(), map()}
  def save(state) do
    path =
      state.session_file ||
        Path.join(
          SessionManager.get_session_dir(state.cwd),
          "#{state.session_manager.header.id}.jsonl"
        )

    case SessionManager.save_to_file(path, state.session_manager) do
      :ok ->
        {:ok, %{state | session_file: path}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @spec append_custom_message(Session.t(), CodingAgent.Messages.CustomMessage.t()) :: Session.t()
  def append_custom_message(
        %Session{} = session_manager,
        %CodingAgent.Messages.CustomMessage{} = message
      ) do
    session_manager
    |> SessionManager.append_custom_message(MessageSerialization.serialize_message(message))
  end

  defp append_custom_message_once(
         %Session{} = session_manager,
         %CodingAgent.Messages.CustomMessage{} = message
       ) do
    serialized = MessageSerialization.serialize_message(message)

    if custom_message_persisted?(session_manager, serialized) do
      session_manager
    else
      SessionManager.append_custom_message(session_manager, serialized)
    end
  end

  defp custom_message_persisted?(%Session{} = session_manager, serialized) do
    Enum.any?(SessionManager.entries(session_manager), fn
      %SessionManager.SessionEntry{type: :custom_message} = entry ->
        entry.custom_type == serialized["custom_type"] and
          entry.content == serialized["content"] and
          entry.display == serialized["display"] and
          entry.details == serialized["details"] and
          entry.timestamp == serialized["timestamp"]

      _ ->
        false
    end)
  end

  defp restore_valid_tool_transcript(messages, session) do
    case TranscriptValidator.validate(messages) do
      :ok ->
        messages

      {:error, {:invalid_tool_transcript, violations}} ->
        if repairable_missing_results?(violations) do
          repair_missing_tool_results(messages, violations, session)
        else
          truncate_invalid_tool_transcript(messages, violations, session)
        end
    end
  end

  defp repair_missing_tool_results(messages, violations, session) do
    repaired =
      messages
      |> Enum.with_index()
      |> Enum.flat_map(fn {message, index} ->
        [
          message
          | synthetic_results_for(
              message,
              Map.get(missing_results_by_index(violations), index, [])
            )
        ]
      end)

    case TranscriptValidator.validate(repaired) do
      :ok ->
        Logger.warning(
          "Repaired restored session transcript by inserting interrupted tool results",
          session_id: session.header.id,
          original_message_count: length(messages),
          restored_message_count: length(repaired),
          violations: inspect(violations)
        )

        repaired

      {:error, {:invalid_tool_transcript, next_violations}} ->
        truncate_invalid_tool_transcript(messages, next_violations, session)
    end
  end

  defp truncate_invalid_tool_transcript(messages, violations, session) do
    case first_indexed_violation(violations) do
      nil ->
        Logger.warning(
          "Dropping restored session transcript with unrepairable tool transcript violation",
          session_id: session.header.id,
          violations: inspect(violations)
        )

        []

      index ->
        restored = Enum.take(messages, index)

        Logger.warning(
          "Truncated restored session transcript at invalid tool transcript segment",
          session_id: session.header.id,
          original_message_count: length(messages),
          restored_message_count: length(restored),
          violations: inspect(violations)
        )

        restored
    end
  end

  defp repairable_missing_results?(violations) do
    Enum.all?(violations, &(&1.type == :missing_tool_result and is_integer(&1.index)))
  end

  defp missing_results_by_index(violations) do
    Map.new(violations, fn violation -> {violation.index, violation.tool_call_ids || []} end)
  end

  defp synthetic_results_for(message, tool_call_ids) do
    Enum.map(tool_call_ids, fn tool_call_id ->
      %Ai.Types.ToolResultMessage{
        role: :tool_result,
        tool_call_id: tool_call_id,
        tool_name: tool_name_for_call(message, tool_call_id),
        content: [
          %Ai.Types.TextContent{
            type: :text,
            text: "Tool call was interrupted before Lemon recorded a result."
          }
        ],
        details: %{"restored_session_repair" => true, "reason" => "interrupted_tool_call"},
        trust: :trusted,
        is_error: true,
        timestamp: message_timestamp(message)
      }
    end)
  end

  defp tool_name_for_call(%Ai.Types.AssistantMessage{content: content}, tool_call_id) do
    content
    |> Enum.find_value("", fn
      %Ai.Types.ToolCall{id: ^tool_call_id, name: name} -> name
      %{id: ^tool_call_id, name: name} -> name
      %{"id" => ^tool_call_id, "name" => name} -> name
      _ -> false
    end)
  end

  defp tool_name_for_call(_message, _tool_call_id), do: ""

  defp message_timestamp(%{timestamp: timestamp}) when is_integer(timestamp), do: timestamp
  defp message_timestamp(_message), do: 0

  defp first_indexed_violation(violations) do
    violations
    |> Enum.map(&Map.get(&1, :index))
    |> Enum.filter(&is_integer/1)
    |> Enum.min(fn -> nil end)
  end
end
