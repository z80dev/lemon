defmodule LemonRouter.RunProcess.Watchdog do
  @moduledoc """
  Idle-run watchdog timer logic for RunProcess.

  Manages scheduling, touching, and cancelling the per-run idle watchdog
  timer, as well as the interactive keepalive confirmation flow for
  Telegram sessions.
  """

  require Logger

  alias LemonChannels.OutboundPayload
  alias LemonRouter.{ChannelContext, ChannelsDelivery}

  @default_run_idle_watchdog_timeout_ms 2 * 60 * 60 * 1000
  @default_run_idle_watchdog_confirm_timeout_ms 5 * 60 * 1000
  @idle_keepalive_continue_callback_prefix "lemon:idle:c:"
  @idle_keepalive_stop_callback_prefix "lemon:idle:k:"

  @spec resolve_run_watchdog_timeout_ms(keyword()) :: pos_integer()
  def resolve_run_watchdog_timeout_ms(opts) do
    timeout_ms =
      opts[:run_watchdog_timeout_ms] ||
        Application.get_env(
          :lemon_router,
          :run_process_idle_watchdog_timeout_ms,
          nil
        ) ||
        Application.get_env(
          :lemon_router,
          :run_process_watchdog_timeout_ms,
          @default_run_idle_watchdog_timeout_ms
        )

    if is_integer(timeout_ms) and timeout_ms > 0,
      do: timeout_ms,
      else: @default_run_idle_watchdog_timeout_ms
  end

  @spec resolve_run_watchdog_confirm_timeout_ms(keyword()) :: pos_integer()
  def resolve_run_watchdog_confirm_timeout_ms(opts) do
    timeout_ms =
      opts[:run_watchdog_confirm_timeout_ms] ||
        Application.get_env(
          :lemon_router,
          :run_process_idle_watchdog_confirm_timeout_ms,
          @default_run_idle_watchdog_confirm_timeout_ms
        )

    if is_integer(timeout_ms) and timeout_ms > 0,
      do: timeout_ms,
      else: @default_run_idle_watchdog_confirm_timeout_ms
  end

  @spec schedule_run_watchdog(map()) :: map()
  def schedule_run_watchdog(state) do
    timeout_ms = state.run_watchdog_timeout_ms || @default_run_idle_watchdog_timeout_ms
    now_ms = LemonCore.Clock.now_ms()
    _ = cancel_run_watchdog_timer(state)
    ref = Process.send_after(self(), :run_watchdog_timeout, timeout_ms)

    run_started_at_ms =
      if is_integer(state.run_started_at_ms), do: state.run_started_at_ms, else: now_ms

    %{
      state
      | run_started_at_ms: run_started_at_ms,
        run_last_activity_at_ms: now_ms,
        run_watchdog_ref: ref
    }
  end

  @spec touch_run_watchdog(map()) :: map()
  def touch_run_watchdog(%{run_started_at_ms: started_at} = state) when is_integer(started_at) do
    state
    |> touch_run_watchdog_activity()
    |> clear_watchdog_confirmation()
    |> schedule_run_watchdog()
  end

  def touch_run_watchdog(state), do: state

  @spec touch_run_watchdog_activity(map()) :: map()
  def touch_run_watchdog_activity(state) do
    %{state | run_last_activity_at_ms: LemonCore.Clock.now_ms()}
  end

  @spec cancel_run_watchdog(map()) :: map()
  def cancel_run_watchdog(%{run_watchdog_ref: nil} = state), do: state

  def cancel_run_watchdog(%{run_watchdog_ref: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | run_watchdog_ref: nil}
  end

  @spec maybe_request_watchdog_confirmation(map()) :: {:ok, map()} | :error
  def maybe_request_watchdog_confirmation(state) do
    with {:ok, payload} <- watchdog_confirmation_payload(state),
         {:ok, _ref} <-
           ChannelsDelivery.enqueue(payload,
             context: %{component: :run_process, phase: :watchdog_keepalive_prompt}
           ) do
      timeout_ms =
        state.run_watchdog_confirm_timeout_ms || @default_run_idle_watchdog_confirm_timeout_ms

      ref = Process.send_after(self(), :run_watchdog_confirmation_timeout, timeout_ms)

      Logger.warning(
        "RunProcess watchdog idle prompt sent run_id=#{inspect(state.run_id)} " <>
          "session_key=#{inspect(state.session_key)} confirm_timeout_ms=#{timeout_ms}"
      )

      {:ok, put_in_watchdog_confirmation(state, ref)}
    else
      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  @spec fail_run_for_idle_timeout(map()) :: map()
  def fail_run_for_idle_timeout(state) do
    timeout_ms = state.run_watchdog_timeout_ms || @default_run_idle_watchdog_timeout_ms

    Logger.error(
      "RunProcess watchdog idle timeout run_id=#{inspect(state.run_id)} " <>
        "session_key=#{inspect(state.session_key)} idle_timeout_ms=#{timeout_ms}"
    )

    emit_synthetic_run_completion(state, {:run_idle_watchdog_timeout, timeout_ms}, timeout_ms)
    clear_watchdog_confirmation(state)
  end

  @spec fail_run_for_user_cancel(map()) :: map()
  def fail_run_for_user_cancel(state) do
    emit_synthetic_run_completion(state, :user_requested, nil)
    clear_watchdog_confirmation(state)
  end

  @spec clear_watchdog_confirmation(map()) :: map()
  def clear_watchdog_confirmation(state) do
    state
    |> cancel_run_watchdog_confirmation()
    |> Map.put(:run_watchdog_awaiting_confirmation?, false)
  end

  @spec cancel_run_watchdog_confirmation(map()) :: map()
  def cancel_run_watchdog_confirmation(%{run_watchdog_confirmation_ref: nil} = state), do: state

  def cancel_run_watchdog_confirmation(%{run_watchdog_confirmation_ref: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | run_watchdog_confirmation_ref: nil}
  end

  # --- Private helpers ---

  defp cancel_run_watchdog_timer(%{run_watchdog_ref: nil}), do: :ok

  defp cancel_run_watchdog_timer(%{run_watchdog_ref: ref}) do
    _ = Process.cancel_timer(ref)
    :ok
  end

  defp watchdog_confirmation_payload(state) do
    parsed = ChannelContext.parse_session_key(state.session_key)

    with "telegram" <- parsed.channel_id,
         peer_kind when peer_kind in [:dm, :group, :channel] <- parsed.peer_kind,
         peer_id when is_binary(peer_id) and peer_id != "" <- parsed.peer_id do
      idle_timeout_ms = state.run_watchdog_timeout_ms || @default_run_idle_watchdog_timeout_ms
      mins = max(1, div(idle_timeout_ms, 60_000))

      text =
        "Still running, but no output for about #{mins} minutes.\n" <>
          "Keep waiting?"

      reply_markup = %{
        "inline_keyboard" => [
          [
            %{
              "text" => "Keep Waiting",
              "callback_data" => @idle_keepalive_continue_callback_prefix <> state.run_id
            },
            %{
              "text" => "Stop Run",
              "callback_data" => @idle_keepalive_stop_callback_prefix <> state.run_id
            }
          ]
        ]
      }

      payload = %OutboundPayload{
        channel_id: "telegram",
        account_id: parsed.account_id || "default",
        peer: %{kind: peer_kind, id: peer_id, thread_id: parsed.thread_id},
        kind: :text,
        content: text,
        idempotency_key: "#{state.run_id}:watchdog:prompt:#{idle_timeout_ms}",
        meta: %{
          run_id: state.run_id,
          session_key: state.session_key,
          reply_markup: reply_markup
        }
      }

      {:ok, payload}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp emit_synthetic_run_completion(state, error, duration_ms) do
    try do
      LemonGateway.Runtime.cancel_by_run_id(state.run_id, :run_watchdog_timeout)
    rescue
      _ -> :ok
    end

    event =
      LemonCore.Event.new(
        :run_completed,
        %{
          completed: %{
            ok: false,
            error: error,
            answer: ""
          },
          duration_ms: duration_ms
        },
        %{
          run_id: state.run_id,
          session_key: state.session_key,
          synthetic: true
        }
      )

    LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(state.run_id), event)
  end

  defp put_in_watchdog_confirmation(state, ref) do
    state
    |> cancel_run_watchdog_confirmation()
    |> Map.put(:run_watchdog_confirmation_ref, ref)
    |> Map.put(:run_watchdog_awaiting_confirmation?, true)
  end
end
