defmodule LemonChannels.Adapters.Telegram.Transport.TopicCommand do
  @moduledoc """
  Telegram-local `/topic` command handler extracted from the transport shell.
  """

  alias LemonChannels.Adapters.Telegram.Transport.Commands

  @type callbacks :: %{
          extract_message_ids: (map() -> {integer() | nil, integer() | nil, integer() | nil}),
          send_system_message: (map(), integer(), integer() | nil, integer() | nil, binary() ->
                                  any())
        }

  @spec handle_topic_command(map(), map(), callbacks()) :: map()
  def handle_topic_command(state, inbound, callbacks) do
    {chat_id, thread_id, user_msg_id} = callbacks.extract_message_ids.(inbound)
    topic_name = String.trim(Commands.telegram_command_args(inbound.message.text, "topic") || "")

    cond do
      not is_integer(chat_id) ->
        state

      topic_name == "" ->
        _ =
          callbacks.send_system_message.(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            topic_usage()
          )

        state

      not function_exported?(state.api_mod, :create_forum_topic, 3) ->
        _ =
          callbacks.send_system_message.(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            "This Telegram API module does not support /topic."
          )

        state

      true ->
        case state.api_mod.create_forum_topic(state.token, chat_id, topic_name) do
          {:ok, %{"ok" => true, "result" => result}} ->
            _ =
              callbacks.send_system_message.(
                state,
                chat_id,
                thread_id,
                user_msg_id,
                topic_created_message(topic_name, result)
              )

            state

          {:ok, %{"result" => result}} ->
            _ =
              callbacks.send_system_message.(
                state,
                chat_id,
                thread_id,
                user_msg_id,
                topic_created_message(topic_name, result)
              )

            state

          {:ok, %{"description" => description}}
          when is_binary(description) and description != "" ->
            _ =
              callbacks.send_system_message.(
                state,
                chat_id,
                thread_id,
                user_msg_id,
                "Failed to create topic: #{description}"
              )

            state

          {:error, reason} ->
            _ =
              callbacks.send_system_message.(
                state,
                chat_id,
                thread_id,
                user_msg_id,
                topic_error_message(reason)
              )

            state

          _ ->
            _ =
              callbacks.send_system_message.(
                state,
                chat_id,
                thread_id,
                user_msg_id,
                "Failed to create topic."
              )

            state
        end
    end
  rescue
    _ -> state
  end

  defp topic_usage, do: "Usage: /topic <name>"

  defp topic_created_message(topic_name, result) when is_binary(topic_name) and is_map(result) do
    topic_id = parse_int(result["message_thread_id"] || result[:message_thread_id])

    if is_integer(topic_id) do
      "Created topic \"#{topic_name}\" (id: #{topic_id})."
    else
      "Created topic \"#{topic_name}\"."
    end
  rescue
    _ -> "Created topic \"#{topic_name}\"."
  end

  defp topic_created_message(topic_name, _result) do
    "Created topic \"#{topic_name}\"."
  end

  defp topic_error_message(reason) do
    case extract_topic_error_description(reason) do
      desc when is_binary(desc) and desc != "" -> "Failed to create topic: #{desc}"
      _ -> "Failed to create topic."
    end
  end

  defp extract_topic_error_description(%{"description" => desc})
       when is_binary(desc) and desc != "" do
    desc
  end

  defp extract_topic_error_description({:http_error, _status, body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"description" => desc}} when is_binary(desc) and desc != "" -> desc
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp extract_topic_error_description(_), do: nil

  defp parse_int(nil), do: nil
  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int(_), do: nil
end
