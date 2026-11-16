defmodule LemonRouter.RunProcess.Watchdog do
  @moduledoc """
  Idle watchdog transitions for the `LemonRouter.RunProcess` state machine.

  The run owns the timeout; this module builds `:gen_statem` actions rather
  than sending timer messages or retaining timer references.

  | State | Event | Next state / timeout |
  | --- | --- | --- |
  | awaiting start | run started | running / idle timeout |
  | running or confirming idle | output, action, keepalive | running / fresh idle timeout |
  | running | idle timeout, prompt delivered | confirming idle / confirmation timeout |
  | running | idle timeout, no prompt destination | completing / synthetic failure |
  | confirming idle | confirmation timeout | completing / synthetic failure |
  | active | cancel | completing / synthetic cancellation |
  | any | unrelated event | unchanged / existing deadline retained |

  Leaving the active state cancels its `state_timeout` automatically. Zero
  idle timeout disables only idle expiry, not cancellation or gateway monitoring.
  """

  require Logger

  alias LemonCore.{DeliveryIntent, DeliveryRoute}
  alias LemonRouter.ChannelContext

  @default_run_idle_watchdog_timeout_ms 2 * 60 * 60 * 1000
  @default_run_idle_watchdog_confirm_timeout_ms 5 * 60 * 1000

  @spec resolve_run_watchdog_timeout_ms(keyword()) :: pos_integer() | nil
  def resolve_run_watchdog_timeout_ms(opts) do
    timeout_ms =
      first_present([
        get_opt(opts, :run_watchdog_timeout_ms),
        Application.get_env(:lemon_router, :run_process_idle_watchdog_timeout_ms, :unset),
        Application.get_env(:lemon_router, :run_process_watchdog_timeout_ms, :unset)
      ])

    case timeout_ms do
      value when is_integer(value) and value > 0 -> value
      0 -> nil
      false -> nil
      nil -> @default_run_idle_watchdog_timeout_ms
      :unset -> @default_run_idle_watchdog_timeout_ms
      _ -> @default_run_idle_watchdog_timeout_ms
    end
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

  @spec start(map()) :: {map(), list()}
  def start(state) do
    now_ms = LemonCore.Clock.now_ms()

    state = %{
      state
      | run_started_at_ms: state.run_started_at_ms || now_ms,
        run_last_activity_at_ms: now_ms
    }

    timeout = state.run_watchdog_timeout_ms || :infinity
    {state, [{:state_timeout, timeout, :idle}]}
  end

  @spec activity(atom(), map()) :: tuple()
  def activity(phase, state) when phase in [:running, :confirming_idle] do
    {state, actions} = start(state)
    {:next_state, :running, state, actions}
  end

  def activity(_phase, state), do: {:keep_state, state}

  @spec request_confirmation(map()) :: :ok | :error
  def request_confirmation(state) do
    with {:ok, intent} <- watchdog_confirmation_intent(state),
         :ok <- dispatcher().dispatch(intent) do
      Logger.warning(
        "RunProcess watchdog idle prompt sent run_id=#{inspect(state.run_id)} " <>
          "session_key=#{inspect(state.session_key)} " <>
          "confirm_timeout_ms=#{state.run_watchdog_confirm_timeout_ms}"
      )

      :ok
    else
      _ -> :error
    end
  end

  @spec fail_run_for_idle_timeout(map()) :: :ok
  def fail_run_for_idle_timeout(state) do
    timeout_ms = state.run_watchdog_timeout_ms || @default_run_idle_watchdog_timeout_ms

    Logger.error(
      "RunProcess watchdog idle timeout run_id=#{inspect(state.run_id)} " <>
        "session_key=#{inspect(state.session_key)} idle_timeout_ms=#{timeout_ms}"
    )

    emit_synthetic_run_completion(state, {:run_idle_watchdog_timeout, timeout_ms}, timeout_ms)
  end

  @spec fail_run_for_user_cancel(map()) :: :ok
  def fail_run_for_user_cancel(state) do
    emit_synthetic_run_completion(state, :user_requested, nil)
  end

  defp watchdog_confirmation_intent(state) do
    parsed = ChannelContext.parse_session_key(state.session_key)

    with "telegram" <- parsed.channel_id,
         peer_kind when peer_kind in [:dm, :group, :channel] <- parsed.peer_kind,
         peer_id when is_binary(peer_id) and peer_id != "" <- parsed.peer_id do
      idle_timeout_ms = state.run_watchdog_timeout_ms || @default_run_idle_watchdog_timeout_ms
      mins = max(1, div(idle_timeout_ms, 60_000))

      text =
        "Still running, but no output for about #{mins} minutes.\n" <>
          "Keep waiting?"

      route = %DeliveryRoute{
        channel_id: "telegram",
        account_id: parsed.account_id || "default",
        peer_kind: peer_kind,
        peer_id: peer_id,
        thread_id: parsed.thread_id
      }

      {:ok,
       %DeliveryIntent{
         intent_id: "#{state.run_id}:watchdog:prompt:#{idle_timeout_ms}",
         run_id: state.run_id,
         session_key: state.session_key,
         route: route,
         kind: :watchdog_prompt,
         body: %{text: text, seq: 0},
         controls: %{allow_cancel?: true, watchdog_prompt?: true},
         meta: %{surface: :status, user_msg_id: nil}
       }}
    else
      _ -> :error
    end
  end

  defp emit_synthetic_run_completion(state, error, duration_ms) do
    try do
      engine_runtime(state).cancel_by_run_id(state.run_id, :run_watchdog_timeout)
    rescue
      _ -> :ok
    end

    event =
      LemonCore.Event.new(
        :run_completed,
        LemonCore.Events.RunCompleted.new(%{
          completed:
            LemonCore.Events.Completion.new(%{
              ok: false,
              error: error,
              answer: ""
            }),
          duration_ms: duration_ms
        }),
        %{
          run_id: state.run_id,
          session_key: state.session_key,
          synthetic: true
        }
      )

    LemonRouter.RunCompletion.publish(state.execution_request, event)
  end

  defp dispatcher do
    Application.get_env(:lemon_router, :dispatcher, LemonChannels.Dispatcher)
  end

  defp first_present(values) do
    Enum.find(values, :unset, &(&1 != :unset))
  end

  defp get_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key, :unset)
  defp get_opt(opts, key) when is_map(opts), do: Map.get(opts, key, :unset)
  defp get_opt(_, _), do: :unset

  defp engine_runtime(state) do
    Map.get(state, :engine_runtime) ||
      Application.get_env(:lemon_router, :engine_runtime)
  end
end
