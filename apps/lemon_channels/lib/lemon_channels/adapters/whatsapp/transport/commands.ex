defmodule LemonChannels.Adapters.WhatsApp.Transport.Commands do
  @moduledoc """
  Command detection, predicate logic, and message-entry helpers for the
  WhatsApp transport.

  All functions here are pure (no side effects, no GenServer state mutation).
  They inspect message text and return booleans or parsed data.

  WhatsApp commands use `/` prefix only — no @bot suffix needed.
  """

  # ---------------------------------------------------------------------------
  # Command predicates
  # ---------------------------------------------------------------------------

  def cancel_command?(text), do: whatsapp_command?(text, "cancel")
  def new_command?(text), do: whatsapp_command?(text, "new")
  def model_command?(text), do: whatsapp_command?(text, "model")
  def thinking_command?(text), do: whatsapp_command?(text, "thinking")

  @doc """
  Returns true when the text looks like any `/command` message.
  """
  def command?(text) do
    String.trim_leading(text || "") |> String.starts_with?("/")
  end

  # ---------------------------------------------------------------------------
  # Message entry / joining helpers
  # ---------------------------------------------------------------------------

  @doc """
  Build a compact entry map from an inbound for buffering purposes.
  """
  def message_entry(inbound) do
    %{
      id: inbound.message.id,
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
  Derive the scope key (used as buffer map key) from an inbound.

  Returns `{peer_id, thread_id}` where peer_id is the JID string.
  """
  def scope_key(inbound) do
    peer_id = inbound.peer.id
    thread_id = inbound.peer.thread_id
    {peer_id, thread_id}
  end

  # ---------------------------------------------------------------------------
  # Command args extraction
  # ---------------------------------------------------------------------------

  @doc """
  Extract the argument portion after `/cmd`.
  """
  def command_args(text, cmd) when is_binary(cmd) do
    trimmed = String.trim_leading(text || "")

    case Regex.run(~r/^\/#{cmd}(?:\s+|$)(.*)$/is, trimmed) do
      [_, rest] -> String.trim(rest || "")
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp whatsapp_command?(text, cmd) when is_binary(cmd) do
    trimmed = String.trim_leading(text || "")

    case Regex.run(~r/^\/#{cmd}(?:\s|$)/i, trimmed) do
      [_] -> true
      _ -> false
    end
  end
end
