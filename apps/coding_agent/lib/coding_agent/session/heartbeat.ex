defmodule CodingAgent.Session.Heartbeat do
  @moduledoc """
  Durable, same-session recurring prompts.

  A heartbeat is deliberately different from cron: it re-enters one live
  `CodingAgent.Session` with an ordinary user message, preserving the current
  transcript and provider prompt cache. The persisted state lives in a custom
  session entry, so reopening the same JSONL session restores the timer without
  introducing a second scheduler or store.

  The session owns dispatch. This module owns state validation, persistence,
  timer bookkeeping, and the prompt rendered when a due heartbeat fires. Its
  slot in the session state is one field, `heartbeat`, holding a
  `CodingAgent.Session.Heartbeat.State`: the persisted configuration plus the
  runtime timers, so the session never touches a timer reference directly.
  """

  require Logger

  alias CodingAgent.Session.Persistence
  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.{Session, SessionEntry}

  @custom_type "session_heartbeat"
  @min_interval_seconds 60
  @max_timer_ms 2_147_483_647
  @idle_defer_ms 25
  @retry_after_persist_error_ms 5_000
  @max_prompt_bytes 16_384

  defmodule State do
    @moduledoc """
    The heartbeat's slot in the session state: the persisted configuration
    (`config`, `nil` when no heartbeat is set), whether it is due, and the
    timers the session process owns for it.
    """

    @type t :: %__MODULE__{
            config: CodingAgent.Session.Heartbeat.t() | nil,
            due: boolean(),
            timer_ref: reference() | nil,
            timer_token: reference() | nil,
            idle_timer_ref: reference() | nil,
            idle_token: reference() | nil
          }

    defstruct config: nil,
              due: false,
              timer_ref: nil,
              timer_token: nil,
              idle_timer_ref: nil,
              idle_token: nil
  end

  @typedoc "One session's persisted heartbeat configuration."
  @type t :: %{
          prompt: String.t(),
          interval_seconds: pos_integer(),
          status: :active | :paused,
          created_at_ms: non_neg_integer(),
          last_fired_at_ms: non_neg_integer(),
          fire_count: non_neg_integer()
        }

  @doc "Minimum supported recurring interval."
  @spec min_interval_seconds() :: pos_integer()
  def min_interval_seconds, do: @min_interval_seconds

  @doc "Restore the latest heartbeat record and schedule its next due check."
  @spec restore(map()) :: map()
  def restore(state) do
    state
    |> cancel_runtime_timers()
    |> put_config(load(state.session_manager))
    |> schedule_next()
  end

  @doc "Read the newest valid heartbeat entry from a persisted session."
  @spec load(Session.t()) :: t() | nil
  def load(%Session{} = session_manager) do
    session_manager
    |> SessionManager.entries()
    |> Enum.reverse()
    |> Enum.find(fn
      %SessionEntry{type: :custom, custom_type: @custom_type} -> true
      _ -> false
    end)
    |> case do
      %SessionEntry{data: data} -> decode(data)
      nil -> nil
    end
  end

  @doc "Return a user-facing status snapshot without exposing runtime timer refs."
  @spec status(State.t() | t() | nil, non_neg_integer()) :: map()
  def status(heartbeat, now_ms \\ now_ms())

  def status(%State{config: config}, now_ms), do: status(config, now_ms)

  def status(nil, _now_ms) do
    %{
      configured: false,
      status: :cleared,
      prompt: nil,
      interval_seconds: nil,
      fire_count: 0,
      created_at_ms: nil,
      last_fired_at_ms: nil,
      next_fire_at_ms: nil,
      next_in_seconds: nil
    }
  end

  def status(%{} = heartbeat, now_ms) do
    next_fire_at_ms = next_fire_at_ms(heartbeat)

    %{
      configured: true,
      status: heartbeat.status,
      prompt: heartbeat.prompt,
      interval_seconds: heartbeat.interval_seconds,
      fire_count: heartbeat.fire_count,
      created_at_ms: heartbeat.created_at_ms,
      last_fired_at_ms: nonzero_or_nil(heartbeat.last_fired_at_ms),
      next_fire_at_ms: if(heartbeat.status == :active, do: next_fire_at_ms),
      next_in_seconds:
        if(heartbeat.status == :active,
          do: max(div(next_fire_at_ms - now_ms + 999, 1_000), 0)
        )
    }
  end

  @doc "Set or replace the current heartbeat and persist it before scheduling."
  @spec set(map(), String.t(), integer()) :: {:ok, map()} | {:error, term(), map()}
  def set(state, prompt, interval_seconds) do
    with {:ok, prompt} <- validate_prompt(prompt),
         :ok <- validate_interval(interval_seconds) do
      now = now_ms()

      heartbeat = %{
        prompt: prompt,
        interval_seconds: interval_seconds,
        status: :active,
        created_at_ms: now,
        last_fired_at_ms: 0,
        fire_count: 0
      }

      persist_and_install(state, heartbeat)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc "Pause the heartbeat without deleting its prompt or history."
  @spec pause(map()) :: {:ok, map()} | {:error, term(), map()}
  def pause(%{heartbeat: %State{config: nil}} = state), do: {:error, :not_configured, state}

  def pause(state) do
    heartbeat = %{state.heartbeat.config | status: :paused}
    persist_and_install(state, heartbeat)
  end

  @doc "Resume and re-anchor the heartbeat so stale time never fires immediately."
  @spec resume(map()) :: {:ok, map()} | {:error, term(), map()}
  def resume(%{heartbeat: %State{config: nil}} = state), do: {:error, :not_configured, state}

  def resume(state) do
    heartbeat = %{state.heartbeat.config | status: :active, last_fired_at_ms: now_ms()}
    persist_and_install(state, heartbeat)
  end

  @doc "Persist a cleared tombstone and remove the live heartbeat."
  @spec clear(map()) :: {:ok, map()} | {:error, term(), map()}
  def clear(%{heartbeat: %State{config: nil}} = state), do: {:error, :not_configured, state}

  def clear(state) do
    data = encode(%{state.heartbeat.config | status: :paused}) |> Map.put("status", "cleared")

    case persist_entry(state, data) do
      {:ok, persisted} ->
        {:ok, persisted |> cancel_runtime_timers() |> put_config(nil)}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @doc "Mark the active timer as due when its token is still current."
  @spec mark_due(map(), reference()) :: map()
  def mark_due(%{heartbeat: %State{timer_token: token} = heartbeat} = state, token)
      when is_reference(token) do
    heartbeat = %{heartbeat | timer_ref: nil, timer_token: nil}
    state = %{state | heartbeat: heartbeat}

    cond do
      not active?(heartbeat.config) ->
        state

      due?(heartbeat.config) ->
        put_due(state, true)

      true ->
        schedule_next(state)
    end
  end

  def mark_due(state, _stale_token), do: state

  @doc "Schedule one short idle check for a due heartbeat."
  @spec schedule_idle_check(map(), non_neg_integer()) :: map()
  def schedule_idle_check(state, delay_ms \\ @idle_defer_ms)

  def schedule_idle_check(
        %{heartbeat: %State{due: true, idle_timer_ref: nil} = heartbeat} = state,
        delay_ms
      )
      when is_integer(delay_ms) and delay_ms >= 0 do
    token = make_ref()
    timer_ref = Process.send_after(self(), {:session_heartbeat_idle, token}, delay_ms)

    %{state | heartbeat: %{heartbeat | idle_timer_ref: timer_ref, idle_token: token}}
  end

  def schedule_idle_check(state, _delay_ms), do: state

  @doc "Consume the current idle-check token, leaving stale checks harmless."
  @spec consume_idle_check(map(), reference()) :: {:current | :stale, map()}
  def consume_idle_check(%{heartbeat: %State{idle_token: token} = heartbeat} = state, token)
      when is_reference(token) do
    {:current, %{state | heartbeat: %{heartbeat | idle_timer_ref: nil, idle_token: nil}}}
  end

  def consume_idle_check(state, _stale_token), do: {:stale, state}

  @doc "Persist a fire claim before the recurring prompt enters the agent loop."
  @spec claim_fire(map()) :: {:ok, String.t(), map()} | {:error, term(), map()}
  def claim_fire(%{heartbeat: %State{config: %{} = heartbeat}} = state) do
    now = now_ms()

    claimed = %{
      heartbeat
      | last_fired_at_ms: now,
        fire_count: heartbeat.fire_count + 1
    }

    case persist_entry(state, encode(claimed)) do
      {:ok, persisted} ->
        next_state =
          persisted
          |> cancel_runtime_timers()
          |> put_config(claimed)
          |> schedule_next()

        {:ok, render_prompt(claimed), next_state}

      {:error, reason} ->
        Logger.warning("Unable to persist due session heartbeat: #{inspect(reason)}")

        {:error, reason,
         state
         |> put_due(true)
         |> schedule_idle_check(@retry_after_persist_error_ms)}
    end
  end

  def claim_fire(state), do: {:error, :not_configured, state}

  @doc "Cancel heartbeat timers when resetting or terminating a session."
  @spec clear_runtime(map()) :: map()
  def clear_runtime(state) do
    state
    |> cancel_runtime_timers()
    |> put_config(nil)
  end

  @doc "Whether a real user-facing prompt is already queued behind the idle check."
  @spec queued_user_input?() :: boolean()
  def queued_user_input? do
    case Process.info(self(), :messages) do
      {:messages, messages} -> Enum.any?(messages, &user_input_message?/1)
      _ -> false
    end
  end

  @doc "Render the ordinary user message injected for a recurring turn."
  @spec render_prompt(t()) :: String.t()
  def render_prompt(heartbeat) do
    """
    [Heartbeat — recurring instruction, fires every #{format_interval(heartbeat.interval_seconds)}]
    #{heartbeat.prompt}

    If there is nothing meaningful to do or report for this instruction right now, reply briefly that nothing has changed and stop — do not invent work.
    """
    |> String.trim()
  end

  @doc "Compact interval formatting used by the TUI and injected prompt."
  @spec format_interval(pos_integer()) :: String.t()
  def format_interval(seconds) when rem(seconds, 86_400) == 0, do: "#{div(seconds, 86_400)}d"
  def format_interval(seconds) when rem(seconds, 3_600) == 0, do: "#{div(seconds, 3_600)}h"
  def format_interval(seconds) when rem(seconds, 60) == 0, do: "#{div(seconds, 60)}m"
  def format_interval(seconds), do: "#{seconds}s"

  defp persist_and_install(state, heartbeat) do
    case persist_entry(state, encode(heartbeat)) do
      {:ok, persisted} ->
        {:ok,
         persisted
         |> cancel_runtime_timers()
         |> put_config(heartbeat)
         |> schedule_next()}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp persist_entry(state, data) do
    session_manager =
      SessionManager.append_entry(
        state.session_manager,
        SessionEntry.custom(@custom_type, data)
      )

    candidate = %{state | session_manager: session_manager}

    case Persistence.save(candidate) do
      {:ok, persisted} -> {:ok, persisted}
      {:error, reason, _unchanged} -> {:error, reason}
    end
  end

  defp schedule_next(%{heartbeat: %State{config: config} = heartbeat} = state) do
    if active?(config) do
      token = make_ref()
      delay_ms = min(max(next_fire_at_ms(config) - now_ms(), 0), @max_timer_ms)
      timer_ref = Process.send_after(self(), {:session_heartbeat_due, token}, delay_ms)
      %{state | heartbeat: %{heartbeat | timer_ref: timer_ref, timer_token: token}}
    else
      state
    end
  end

  defp cancel_runtime_timers(state) do
    heartbeat = slot(state)
    cancel_timer(heartbeat.timer_ref)
    cancel_timer(heartbeat.idle_timer_ref)

    Map.put(state, :heartbeat, %{
      heartbeat
      | timer_ref: nil,
        timer_token: nil,
        idle_timer_ref: nil,
        idle_token: nil
    })
  end

  # A state built before the heartbeat slot existed (a bare map in a test)
  # gets an empty slot rather than a KeyError.
  defp slot(state), do: Map.get(state, :heartbeat) || %State{}

  defp put_config(state, config),
    do: Map.put(state, :heartbeat, %{slot(state) | config: config, due: false})

  defp put_due(state, due?), do: Map.put(state, :heartbeat, %{slot(state) | due: due?})

  defp cancel_timer(ref) when is_reference(ref) do
    _ = Process.cancel_timer(ref)
    :ok
  end

  defp cancel_timer(_), do: :ok

  defp due?(heartbeat), do: next_fire_at_ms(heartbeat) <= now_ms()

  defp next_fire_at_ms(heartbeat) do
    anchor = max(heartbeat.last_fired_at_ms, heartbeat.created_at_ms)
    anchor + heartbeat.interval_seconds * 1_000
  end

  defp active?(%{status: :active}), do: true
  defp active?(_), do: false

  defp validate_prompt(prompt) when is_binary(prompt) do
    prompt = String.trim(prompt)

    cond do
      prompt == "" -> {:error, :empty_prompt}
      byte_size(prompt) > @max_prompt_bytes -> {:error, :prompt_too_large}
      true -> {:ok, prompt}
    end
  end

  defp validate_prompt(_), do: {:error, :invalid_prompt}

  defp validate_interval(seconds)
       when is_integer(seconds) and seconds >= @min_interval_seconds,
       do: :ok

  defp validate_interval(seconds) when is_integer(seconds), do: {:error, :interval_too_small}
  defp validate_interval(_), do: {:error, :invalid_interval}

  defp encode(heartbeat) do
    %{
      "prompt" => heartbeat.prompt,
      "interval_seconds" => heartbeat.interval_seconds,
      "status" => Atom.to_string(heartbeat.status),
      "created_at_ms" => heartbeat.created_at_ms,
      "last_fired_at_ms" => heartbeat.last_fired_at_ms,
      "fire_count" => heartbeat.fire_count
    }
  end

  defp decode(data) when is_map(data) do
    status = value(data, "status")

    if status == "cleared" do
      nil
    else
      heartbeat = %{
        prompt: value(data, "prompt"),
        interval_seconds: value(data, "interval_seconds"),
        status: decode_status(status),
        created_at_ms: value(data, "created_at_ms") || 0,
        last_fired_at_ms: value(data, "last_fired_at_ms") || 0,
        fire_count: value(data, "fire_count") || 0
      }

      if valid_persisted?(heartbeat), do: heartbeat, else: nil
    end
  end

  defp decode(_), do: nil

  defp valid_persisted?(heartbeat) do
    is_binary(heartbeat.prompt) and String.trim(heartbeat.prompt) != "" and
      byte_size(heartbeat.prompt) <= @max_prompt_bytes and
      is_integer(heartbeat.interval_seconds) and
      heartbeat.interval_seconds >= @min_interval_seconds and
      heartbeat.status in [:active, :paused] and
      is_integer(heartbeat.created_at_ms) and heartbeat.created_at_ms >= 0 and
      is_integer(heartbeat.last_fired_at_ms) and heartbeat.last_fired_at_ms >= 0 and
      is_integer(heartbeat.fire_count) and heartbeat.fire_count >= 0
  end

  defp decode_status("active"), do: :active
  defp decode_status(:active), do: :active
  defp decode_status("paused"), do: :paused
  defp decode_status(:paused), do: :paused
  defp decode_status(_), do: :invalid

  defp value(map, "prompt"), do: Map.get(map, "prompt") || Map.get(map, :prompt)

  defp value(map, "interval_seconds"),
    do: Map.get(map, "interval_seconds") || Map.get(map, :interval_seconds)

  defp value(map, "status"), do: Map.get(map, "status") || Map.get(map, :status)

  defp value(map, "created_at_ms"),
    do: Map.get(map, "created_at_ms") || Map.get(map, :created_at_ms)

  defp value(map, "last_fired_at_ms"),
    do: Map.get(map, "last_fired_at_ms") || Map.get(map, :last_fired_at_ms)

  defp value(map, "fire_count"),
    do: Map.get(map, "fire_count") || Map.get(map, :fire_count)

  defp nonzero_or_nil(0), do: nil
  defp nonzero_or_nil(value), do: value

  defp user_input_message?({:"$gen_call", _from, {:prompt, _text, _opts}}), do: true
  defp user_input_message?({:"$gen_call", _from, {:handle_async_followup, _message}}), do: true
  defp user_input_message?({:"$gen_call", _from, {:deliver_parent_question, _text}}), do: true
  defp user_input_message?({:"$gen_cast", {:steer, _text}}), do: true
  defp user_input_message?({:"$gen_cast", {:redirect, _text}}), do: true
  defp user_input_message?({:"$gen_cast", {:follow_up, _text}}), do: true
  defp user_input_message?(_), do: false

  defp now_ms, do: System.system_time(:millisecond)
end
