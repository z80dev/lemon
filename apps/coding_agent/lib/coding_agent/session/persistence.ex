defmodule CodingAgent.Session.Persistence do
  @moduledoc false

  require Logger

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
end
