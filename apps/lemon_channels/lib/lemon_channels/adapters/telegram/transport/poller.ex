defmodule LemonChannels.Adapters.Telegram.Transport.Poller do
  @moduledoc """
  Telegram long-polling logic for the transport GenServer.

  Encapsulates the update-fetching cycle, offset management, webhook conflict
  auto-recovery, and poll-error rate-limiting. All functions operate on the
  transport state map and return an updated state.
  """

  require Logger

  alias LemonChannels.Adapters.Telegram.Transport.UpdateProcessor
  alias LemonChannels.Telegram.OffsetStore
  alias LemonChannels.Telegram.PollerLock

  @webhook_clear_retry_ms 5 * 60 * 1000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Execute a single polling cycle: heartbeat, fetch updates, process them,
  and advance the offset.

  Returns the updated state.
  """
  def poll_updates(state, process_single_update_fn) do
    _ = PollerLock.heartbeat(state.account_id, state.token)

    case safe_get_updates(state) do
      {:ok, %{"ok" => true, "result" => updates}} ->
        if state.drop_pending_updates? and not state.drop_pending_done? do
          if updates == [] do
            # Nothing to drop; we're at the live edge.
            %{state | drop_pending_done?: true}
          else
            # Keep dropping until Telegram returns an empty batch (there can be >100 pending).
            max_id = max_update_id(updates, state.offset)
            new_offset = max(state.offset, max_id + 1)
            persist_offset(state, new_offset)
            %{state | offset: new_offset, drop_pending_done?: false}
          end
        else
          {state, max_id} = handle_updates(state, updates, process_single_update_fn)
          new_offset = max(state.offset, max_id + 1)
          persist_offset(state, new_offset)
          %{state | offset: new_offset}
        end

      {:error, reason} ->
        maybe_log_poll_error(state, reason)

      other ->
        maybe_log_poll_error(state, other)
    end
  rescue
    e ->
      Logger.warning("Telegram poll error: #{inspect(e)}")
      state
  end

  @doc """
  Compute the initial offset from config and stored values.
  """
  def initial_offset(config_offset, stored_offset) do
    cond do
      is_integer(config_offset) -> config_offset
      is_integer(stored_offset) -> stored_offset
      true -> 0
    end
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp safe_get_updates(state) do
    try do
      state.api_mod.get_updates(state.token, state.offset, state.poll_interval_ms)
    catch
      :exit, reason ->
        Logger.debug("Telegram get_updates exited: #{inspect(reason)}")
        {:error, {:exit, reason}}
    end
  end

  defp handle_updates(state, updates, process_single_update_fn) do
    # If updates is empty, keep max_id at offset - 1 so we don't accidentally advance the offset.
    Enum.reduce(updates, {state, state.offset - 1}, fn update, {acc_state, max_id} ->
      id = update["update_id"] || max_id
      acc_state = UpdateProcessor.maybe_index_known_target(acc_state, update)
      acc_state = process_single_update_fn.(acc_state, update, id)
      {acc_state, max(max_id, id)}
    end)
  end

  @doc """
  Return the maximum update_id found in a list of updates, falling back to
  `offset - 1` when the list is empty.
  """
  def max_update_id([], offset), do: offset - 1

  def max_update_id(updates, offset) do
    Enum.reduce(updates, offset - 1, fn update, acc ->
      case update["update_id"] do
        id when is_integer(id) -> max(acc, id)
        _ -> acc
      end
    end)
  end

  defp persist_offset(state, new_offset) do
    if new_offset != state.offset do
      OffsetStore.put(state.account_id, state.token, new_offset)
    end

    :ok
  end

  defp maybe_log_poll_error(state, reason) do
    state = maybe_attempt_webhook_clear(state, reason)

    now = System.monotonic_time(:millisecond)
    last_ts = state.last_poll_error_log_ts
    last_reason = state.last_poll_error

    should_log? =
      cond do
        is_nil(last_ts) ->
          true

        now - last_ts > 60_000 ->
          true

        last_reason != reason ->
          true

        true ->
          false
      end

    if should_log? do
      msg =
        case reason do
          {:http_error, 409, body} ->
            body_s = body |> to_string() |> String.slice(0, 200)

            "Telegram getUpdates returned HTTP 409 Conflict (#{body_s}). " <>
              "This usually means a webhook is set for the bot, which conflicts with polling. " <>
              "Fix: call Telegram Bot API deleteWebhook (optionally with drop_pending_updates=true), " <>
              "then restart the gateway."

          other ->
            "Telegram getUpdates failed: #{inspect(other)}"
        end

      Logger.warning(msg)
    end

    %{state | last_poll_error: reason, last_poll_error_log_ts: now}
  rescue
    _ -> state
  end

  defp maybe_attempt_webhook_clear(state, {:http_error, 409, _body}) do
    now = System.monotonic_time(:millisecond)
    last_attempt = state[:last_webhook_clear_ts]

    should_attempt? =
      is_nil(last_attempt) or
        (is_integer(last_attempt) and now - last_attempt >= @webhook_clear_retry_ms)

    if should_attempt? do
      result =
        try do
          state.api_mod.delete_webhook(state.token, drop_pending_updates: false)
        rescue
          e -> {:error, e}
        end

      case result do
        {:ok, %{"ok" => true}} ->
          Logger.warning(
            "Telegram auto-recovery: deleteWebhook succeeded after getUpdates 409 conflict"
          )

        other ->
          Logger.warning(
            "Telegram auto-recovery: deleteWebhook failed after getUpdates 409 conflict: #{inspect(other)}"
          )
      end

      %{state | last_webhook_clear_ts: now}
    else
      state
    end
  end

  defp maybe_attempt_webhook_clear(state, _reason), do: state
end
