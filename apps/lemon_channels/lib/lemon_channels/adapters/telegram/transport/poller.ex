defmodule LemonChannels.Adapters.Telegram.Transport.Poller do
  @moduledoc """
  Poll-loop and Telegram update dispatch helpers for the Telegram transport shell.
  """

  require Logger

  alias LemonChannels.Adapters.Telegram.Transport.{ActionRunner, Normalize, Pipeline}
  alias LemonChannels.Telegram.PollerLock

  @webhook_clear_retry_ms 5 * 60 * 1000

  @type callbacks :: %{
          handle_callback_query: (map(), map() -> any()),
          execute_inbound_message: (map(), map() -> map()),
          index_known_target: (map(), map() -> map()),
          maybe_log_drop: (map(), map(), term() -> any()),
          maybe_transcribe_voice: (map(), map() ->
                                     {:ok, map()} | {:error, term()} | {:skip, map()}),
          process_media_group: (map(), map() -> any()),
          persist_offset: (map(), integer() -> any()),
          send_approval_request: (map(), map() -> any()),
          start_async_task: (map(), (-> any()) -> any()),
          submit_buffer: (map(), map() -> map())
        }

  @spec poll_updates(map(), callbacks()) :: map()
  def poll_updates(state, callbacks) when is_map(state) and is_map(callbacks) do
    _ = PollerLock.heartbeat(state.account_id, state.token)

    case safe_get_updates(state) do
      {:ok, %{"ok" => true, "result" => updates}} ->
        if state.drop_pending_updates? and not state.drop_pending_done? do
          if updates == [] do
            %{state | drop_pending_done?: true}
          else
            max_id = max_update_id(updates, state.offset)
            new_offset = max(state.offset, max_id + 1)
            callbacks.persist_offset.(state, new_offset)
            %{state | offset: new_offset, drop_pending_done?: false}
          end
        else
          {state, max_id} = handle_updates(state, updates, callbacks)
          new_offset = max(state.offset, max_id + 1)
          callbacks.persist_offset.(state, new_offset)
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

  defp handle_updates(state, updates, callbacks) do
    Enum.reduce(updates, {state, state.offset - 1}, fn update, {acc_state, max_id} ->
      id = update["update_id"] || max_id
      acc_state = process_single_update(acc_state, update, id, callbacks)
      {acc_state, max(max_id, id)}
    end)
  end

  defp process_single_update(state, update, id, callbacks) do
    with {:ok, normalized} <- Normalize.event(state, update, id) do
      case maybe_transcribe_event(state, normalized, callbacks) do
        {:ok, normalized} ->
          {state, actions} = Pipeline.run(normalized, state)
          ActionRunner.run(state, actions, callbacks)

        {:skip, new_state} ->
          new_state

        {:error, _reason} ->
          state
      end
    else
      {:skip, new_state} -> new_state
      {:error, _reason} -> state
    end
  end

  defp maybe_transcribe_event(state, %{kind: :message, inbound: inbound} = normalized, callbacks) do
    case callbacks.maybe_transcribe_voice.(state, inbound) do
      {:ok, inbound} ->
        {:ok, %{normalized | inbound: inbound, text: inbound.message.text}}

      {:skip, new_state} ->
        {:skip, new_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_transcribe_event(_state, normalized, _callbacks), do: {:ok, normalized}

  defp maybe_log_poll_error(state, reason) do
    state = maybe_attempt_webhook_clear(state, reason)

    now = System.monotonic_time(:millisecond)
    last_ts = state.last_poll_error_log_ts
    last_reason = state.last_poll_error

    should_log? =
      cond do
        is_nil(last_ts) -> true
        now - last_ts > 60_000 -> true
        last_reason != reason -> true
        true -> false
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

  defp safe_get_updates(state) do
    try do
      state.api_mod.get_updates(state.token, state.offset, state.poll_interval_ms)
    catch
      :exit, reason ->
        Logger.debug("Telegram get_updates exited: #{inspect(reason)}")
        {:error, {:exit, reason}}
    end
  end

  defp max_update_id([], current_offset), do: current_offset - 1

  defp max_update_id(updates, fallback),
    do: Enum.reduce(updates, fallback, &max(&1["update_id"] || fallback, &2))
end
