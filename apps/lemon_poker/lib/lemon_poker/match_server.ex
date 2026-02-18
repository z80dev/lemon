defmodule LemonPoker.MatchServer do
  @moduledoc false

  use GenServer

  alias LemonPoker.{MatchControl, MatchRunner, TableTalkPolicy, View}

  @name __MODULE__
  @topic "lemon_poker:events"
  @max_events 400

  @type status :: :idle | :running | :paused | :stopping | :stopped | :completed | :error

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec snapshot() :: map()
  def snapshot do
    GenServer.call(@name, :snapshot)
  end

  @spec start_match(keyword()) :: {:ok, map()} | {:error, :match_running | term()}
  def start_match(opts) when is_list(opts) do
    GenServer.call(@name, {:start_match, opts})
  end

  @spec pause_match() :: {:ok, map()} | {:error, term()}
  def pause_match, do: GenServer.call(@name, :pause_match)

  @spec resume_match() :: {:ok, map()} | {:error, term()}
  def resume_match, do: GenServer.call(@name, :resume_match)

  @spec stop_match() :: {:ok, map()} | {:error, term()}
  def stop_match, do: GenServer.call(@name, :stop_match)

  @spec push_table_talk(map()) :: {:ok, map()} | {:error, term()}
  def push_table_talk(payload) when is_map(payload) do
    GenServer.call(@name, {:push_table_talk, payload})
  end

  @impl true
  def init(_opts) do
    {:ok,
     %{
       status: :idle,
       config: nil,
       seats: [],
       table: nil,
       hand_index: 0,
       events: [],
       next_seq: 1,
       started_at: nil,
       finished_at: nil,
       last_error: nil,
       control: nil,
       runner_pid: nil,
       runner_ref: nil
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, state_snapshot(state), state}
  end

  def handle_call({:start_match, _opts}, _from, state)
      when state.status in [:running, :paused, :stopping] do
    {:reply, {:error, :match_running}, state}
  end

  def handle_call({:start_match, opts}, _from, state) do
    control = MatchControl.new()
    parent = self()

    case Task.Supervisor.start_child(LemonPoker.TaskSupervisor, fn ->
           result =
             MatchRunner.run(opts, fn event -> send(parent, {:runner_event, event}) end, control)

           send(parent, {:runner_finished, result})
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        new_state =
          %{state | status: :running}
          |> reset_runtime_state(opts)
          |> Map.put(:control, control)
          |> Map.put(:runner_pid, pid)
          |> Map.put(:runner_ref, ref)

        {:reply, {:ok, state_snapshot(new_state)}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:pause_match, _from, %{status: :running, control: control} = state) do
    :ok = MatchControl.pause(control)

    new_state =
      state |> Map.put(:status, :paused) |> add_event(%{type: "match_paused", status: :paused})

    {:reply, {:ok, state_snapshot(new_state)}, new_state}
  end

  def handle_call(:pause_match, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call(:resume_match, _from, %{status: :paused, control: control} = state) do
    :ok = MatchControl.resume(control)

    new_state =
      state |> Map.put(:status, :running) |> add_event(%{type: "match_resumed", status: :running})

    {:reply, {:ok, state_snapshot(new_state)}, new_state}
  end

  def handle_call(:resume_match, _from, state) do
    {:reply, {:error, :not_paused}, state}
  end

  def handle_call(:stop_match, _from, %{status: status, control: control} = state)
      when status in [:running, :paused] do
    :ok = MatchControl.resume(control)
    :ok = MatchControl.stop(control)

    new_state =
      state
      |> Map.put(:status, :stopping)
      |> add_event(%{type: "match_stopping", status: :stopping})

    {:reply, {:ok, state_snapshot(new_state)}, new_state}
  end

  def handle_call(:stop_match, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call({:push_table_talk, payload}, _from, state) do
    seat = normalize_seat(payload["seat"] || payload[:seat])
    actor = payload["actor"] || payload[:actor] || "host"
    text = payload["text"] || payload[:text] || ""

    if is_integer(seat) and is_binary(text) and String.trim(text) != "" do
      trimmed = String.trim(text)

      case TableTalkPolicy.evaluate(trimmed, hand_live?(state.table)) do
        :allow ->
          event = %{
            type: "table_talk",
            seat: seat,
            actor: actor,
            text: trimmed,
            hand_index: state.hand_index,
            table: state.table
          }

          new_state = add_event(state, event)
          {:reply, {:ok, state_snapshot(new_state)}, new_state}

        {:block, :card_reveal_during_live_hand} ->
          {:reply, {:error, :card_reveal_forbidden_while_hand_live}, state}

        {:block, :strategy_commentary_during_live_hand} ->
          {:reply, {:error, :strategy_commentary_forbidden_while_hand_live}, state}

        {:block, _} ->
          {:reply, {:error, :invalid_payload}, state}
      end
    else
      {:reply, {:error, :invalid_payload}, state}
    end
  end

  @impl true
  def handle_info({:runner_event, event}, state) when is_map(event) do
    new_state = state |> apply_runner_event(event) |> add_event(event)
    {:noreply, new_state}
  end

  def handle_info({:runner_finished, result}, state) do
    new_status =
      case result do
        {:ok, _table} -> :completed
        {:stopped, _table} -> :stopped
        {:error, _reason, _table} -> :error
      end

    {table, last_error} =
      case result do
        {:ok, table} -> {View.table_snapshot(table), nil}
        {:stopped, table} -> {View.table_snapshot(table), nil}
        {:error, reason, table} -> {View.table_snapshot(table), reason}
      end

    finished_state = %{
      state
      | status: new_status,
        table: table,
        finished_at: now_iso(),
        last_error: last_error,
        control: nil,
        runner_pid: nil,
        runner_ref: nil
    }

    {:noreply, finished_state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{runner_ref: ref} = state) do
    if state.runner_pid && reason not in [:normal, :shutdown] do
      new_state =
        state
        |> Map.put(:status, :error)
        |> Map.put(:finished_at, now_iso())
        |> Map.put(:last_error, reason)
        |> Map.put(:control, nil)
        |> Map.put(:runner_pid, nil)
        |> Map.put(:runner_ref, nil)
        |> add_event(%{
          type: "match_error",
          status: :error,
          reason: inspect(reason),
          table: state.table
        })

      {:noreply, new_state}
    else
      {:noreply, %{state | runner_pid: nil, runner_ref: nil}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp reset_runtime_state(state, opts) do
    %{
      state
      | config: opts_to_public_map(opts),
        seats: [],
        table: nil,
        hand_index: 0,
        events: [],
        next_seq: 1,
        started_at: now_iso(),
        finished_at: nil,
        last_error: nil
    }
  end

  defp apply_runner_event(state, event) do
    table = event[:table] || state.table
    seats = event[:seats] || state.seats
    hand_index = event[:hand_index] || state.hand_index

    status =
      case event[:status] do
        nil ->
          case event[:type] do
            "match_started" -> :running
            "match_paused" -> :paused
            "match_resumed" -> :running
            "match_stopping" -> :stopping
            "match_stopped" -> :stopped
            "match_completed" -> :completed
            "match_error" -> :error
            _ -> state.status
          end

        value ->
          normalize_status(value, state.status)
      end

    %{
      state
      | table: table,
        seats: seats,
        hand_index: hand_index,
        status: status,
        finished_at:
          if(status in [:completed, :stopped, :error], do: now_iso(), else: state.finished_at)
    }
  end

  defp add_event(state, event) do
    seq = state.next_seq

    payload =
      event
      |> Map.put_new(:ts, now_iso())
      |> Map.put(:seq, seq)

    Phoenix.PubSub.broadcast(LemonCore.PubSub, @topic, {:poker_event, payload})

    events =
      (state.events ++ [payload])
      |> trim_events(@max_events)

    %{state | events: events, next_seq: seq + 1}
  end

  defp trim_events(events, max_count) when length(events) <= max_count, do: events

  defp trim_events(events, max_count) do
    drop = length(events) - max_count
    Enum.drop(events, drop)
  end

  defp state_snapshot(state) do
    %{
      status: Atom.to_string(state.status),
      config: state.config,
      seats: state.seats,
      table: state.table,
      hand_index: state.hand_index,
      events: state.events,
      started_at: state.started_at,
      finished_at: state.finished_at,
      last_error: state.last_error
    }
  end

  defp opts_to_public_map(opts) when is_list(opts) do
    %{
      table_id: Keyword.get(opts, :table_id),
      players: Keyword.get(opts, :players),
      hands: Keyword.get(opts, :hands),
      stack: Keyword.get(opts, :stack),
      small_blind: Keyword.get(opts, :small_blind),
      big_blind: Keyword.get(opts, :big_blind),
      agent_id: Keyword.get(opts, :agent_id),
      table_talk_enabled: Keyword.get(opts, :table_talk_enabled, true)
    }
  end

  defp normalize_seat(value) when is_integer(value), do: value

  defp normalize_seat(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_seat(_), do: nil

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp hand_live?(%{} = table) do
    case Map.get(table, :hand) || Map.get(table, "hand") do
      %{} -> true
      _ -> false
    end
  end

  defp hand_live?(_), do: false

  defp normalize_status(value, fallback) when is_atom(value) do
    if value in [:idle, :running, :paused, :stopping, :stopped, :completed, :error],
      do: value,
      else: fallback
  end

  defp normalize_status(value, fallback) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "idle" -> :idle
      "running" -> :running
      "paused" -> :paused
      "stopping" -> :stopping
      "stopped" -> :stopped
      "completed" -> :completed
      "error" -> :error
      _ -> fallback
    end
  end

  defp normalize_status(_value, fallback), do: fallback
end
