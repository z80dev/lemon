defmodule LemonChannels.Adapters.Telegram.Transport.MediaGroups do
  @moduledoc """
  Media-group coalescence logic for the Telegram transport.

  Telegram sends album/document-group uploads as individual messages that
  share a `media_group_id`. This module buffers those messages, applies a
  debounce timer, and provides a flush function that hands off the complete
  group for processing.
  """

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  alias LemonChannels.Adapters.Telegram.Transport.FileOperations

  @doc """
  Returns true when the inbound message belongs to a Telegram media group
  (i.e. has both a `media_group_id` and any media attachment in its meta).
  """
  def media_group_member?(inbound) do
    mg = inbound.meta && (inbound.meta[:media_group_id] || inbound.meta["media_group_id"])
    is_binary(mg) and mg != "" and FileOperations.has_media?(inbound)
  rescue
    _ -> false
  end

  @doc """
  Returns true when a group buffer for this inbound's media group already
  exists in state.
  """
  def media_group_exists?(state, inbound) do
    key = media_group_key(state, inbound)
    Map.has_key?(state.media_groups || %{}, key)
  rescue
    _ -> false
  end

  @doc """
  Compute the key that identifies a media group within GenServer state.
  """
  def media_group_key(state, inbound) do
    account_id = state.account_id || "default"
    {chat_id, thread_id} = extract_chat_ids(inbound)
    mg = inbound.meta && (inbound.meta[:media_group_id] || inbound.meta["media_group_id"])

    {account_id, chat_id, thread_id, mg}
  end

  @doc """
  Enqueue an inbound into its media-group buffer, creating the buffer if needed.

  Returns the updated state.
  """
  def enqueue_media_group(state, inbound) do
    group_key = media_group_key(state, inbound)
    debounce_ms = media_group_debounce_ms(state)

    case Map.get(state.media_groups, group_key) do
      nil ->
        debounce_ref = make_ref()

        timer_ref =
          Process.send_after(
            self(),
            {:media_group_flush, group_key, debounce_ref},
            debounce_ms
          )

        group = %{
          items: [inbound],
          timer_ref: timer_ref,
          debounce_ref: debounce_ref
        }

        %{state | media_groups: Map.put(state.media_groups, group_key, group)}

      group ->
        _ = Process.cancel_timer(group.timer_ref)
        debounce_ref = make_ref()

        timer_ref =
          Process.send_after(
            self(),
            {:media_group_flush, group_key, debounce_ref},
            debounce_ms
          )

        group = %{
          group
          | items: [inbound | group.items],
            timer_ref: timer_ref,
            debounce_ref: debounce_ref
        }

        %{state | media_groups: Map.put(state.media_groups, group_key, group)}
    end
  rescue
    _ -> state
  end

  @doc """
  Return the debounce interval (in ms) for media-group coalescence.
  """
  def media_group_debounce_ms(state) do
    cfg = files_cfg(state)
    parse_int(cfg_get(cfg, :media_group_debounce_ms)) || 1_000
  rescue
    _ -> 1_000
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp extract_chat_ids(inbound) do
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
    thread_id = parse_int(inbound.peer.thread_id)
    {chat_id, thread_id}
  end

  defp files_cfg(state) do
    cfg = state.files || %{}
    if is_map(cfg), do: cfg, else: %{}
  end

  defp cfg_get(cfg, key) when is_atom(key) do
    cfg[key] || cfg[Atom.to_string(key)]
  end

  defp parse_int(nil), do: nil
  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end
end
