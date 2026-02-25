defmodule LemonChannels.Adapters.Telegram.Transport.Commands do
  @moduledoc """
  Command detection, predicate logic, and message-entry helpers for the
  Telegram transport.

  All functions here are pure (no side effects, no GenServer state mutation).
  They inspect message text and return booleans or parsed data.
  """

  # ---------------------------------------------------------------------------
  # Command predicates
  # ---------------------------------------------------------------------------

  def cancel_command?(text, bot_username), do: telegram_command?(text, "cancel", bot_username)
  def new_command?(text, bot_username), do: telegram_command?(text, "new", bot_username)
  def resume_command?(text, bot_username), do: telegram_command?(text, "resume", bot_username)
  def model_command?(text, bot_username), do: telegram_command?(text, "model", bot_username)
  def thinking_command?(text, bot_username), do: telegram_command?(text, "thinking", bot_username)
  def reload_command?(text, bot_username), do: telegram_command?(text, "reload", bot_username)
  def trigger_command?(text, bot_username), do: telegram_command?(text, "trigger", bot_username)
  def cwd_command?(text, bot_username), do: telegram_command?(text, "cwd", bot_username)
  def topic_command?(text, bot_username), do: telegram_command?(text, "topic", bot_username)
  def file_command?(text, bot_username), do: telegram_command?(text, "file", bot_username)

  # ---------------------------------------------------------------------------
  # Message entry / joining helpers
  # ---------------------------------------------------------------------------

  @doc """
  Build a compact entry map from an inbound for buffering purposes.
  """
  def message_entry(inbound) do
    %{
      id: parse_int(inbound.message.id) || inbound.meta[:user_msg_id],
      text: inbound.message.text || "",
      reply_to_text: inbound.meta[:reply_to_text],
      reply_to_id: inbound.message.reply_to_id
    }
  end

  @doc """
  Join a list of message entries (oldest-first) into a single text block.

  Returns `{joined_text, last_id, last_reply_to_text, last_reply_to_id}`.
  """
  def join_messages(messages) do
    text = Enum.map_join(messages, "\n\n", & &1.text)
    last = List.last(messages)
    {text, last.id, last.reply_to_text, last.reply_to_id}
  end

  @doc """
  Derive the scope key (used as buffer / media-group map key) from an inbound.
  """
  def scope_key(inbound) do
    chat_id = inbound.meta[:chat_id] || inbound.peer.id
    thread_id = inbound.peer.thread_id
    {chat_id, thread_id}
  end

  # ---------------------------------------------------------------------------
  # Telegram command parsing helpers
  # ---------------------------------------------------------------------------

  @doc """
  Check whether `text` starts with `/cmd` (optionally suffixed with `@BotName`).
  """
  def telegram_command?(text, cmd, bot_username) when is_binary(cmd) do
    trimmed = String.trim_leading(text || "")

    case Regex.run(~r/^\/#{cmd}(?:@([\w_]+))?(?:\s|$)/i, trimmed) do
      [_full] -> true
      [_, nil] -> true
      [_, ""] -> true

      [_, target] when is_binary(bot_username) and bot_username != "" ->
        String.downcase(target) == String.downcase(bot_username)

      [_, _target] -> true
      _ -> false
    end
  end

  @doc """
  Extract the argument portion after `/cmd[@BotName]`.
  """
  def telegram_command_args(text, cmd) when is_binary(cmd) do
    trimmed = String.trim_leading(text || "")

    case Regex.run(~r/^\/#{cmd}(?:@[\w_]+)?(?:\s+|$)(.*)$/is, trimmed) do
      [_, rest] -> String.trim(rest || "")
      _ -> nil
    end
  end

  @doc """
  Returns true when the text looks like a `/command` message.
  """
  def command_message?(text) do
    String.trim_leading(text || "") |> String.starts_with?("/")
  end

  @doc """
  Returns true when the text looks like a `/command` that is addressed to the
  given bot (no @suffix, or @suffix matches bot_username).
  """
  def command_message_for_bot?(text, bot_username) do
    trimmed = String.trim_leading(text || "")

    case Regex.run(~r{^/([a-z][a-z0-9_]*)(?:@([\w_]+))?(?:\s|$)}i, trimmed) do
      [_, _cmd, nil] -> true
      [_, _cmd, ""] -> true

      [_, _cmd, target] when is_binary(bot_username) and bot_username != "" ->
        String.downcase(target) == String.downcase(bot_username)

      [_, _cmd, _target] -> true
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp parse_int(nil), do: nil
  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end
end
