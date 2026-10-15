defmodule LemonChannels.TypingIndicator do
  @moduledoc """
  Best-effort typing refreshers for accepted, chat-originated runs.

  One refresher serves each platform/account/chat/thread, even when runs overlap.
  Run-topic completion, final delivery, cancellation, transport death and a ten-minute
  cap release it. API calls run outside the server and are killed on release; slow
  or failing APIs never block a transport or create overlapping requests.
  """

  use GenServer
  require Logger

  alias LemonCore.{Bus, Event, RunStore}

  @default_cap_ms 600_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Register an accepted run. Options include target, send, interval_ms and session_key."
  def start_run(run_id, opts, server \\ __MODULE__) do
    best_effort(fn -> GenServer.call(server, {:start, run_id, self(), opts}) end)
  end

  def stop_run(run_id, server \\ __MODULE__) do
    best_effort(fn -> GenServer.call(server, {:stop_run, run_id}) end)
  end

  def stop_session(session_key, server \\ __MODULE__) do
    best_effort(fn -> GenServer.call(server, {:stop_session, session_key}) end)
  end

  @impl true
  def init(_opts), do: {:ok, %{targets: %{}, runs: %{}}}

  @impl true
  def handle_call({:start, run_id, owner, opts}, _from, state) do
    if Map.has_key?(state.runs, run_id) do
      {:reply, :ok, state}
    else
      :ok = Bus.subscribe(Bus.run_topic(run_id))

      # A fast run may have completed between the submission acknowledgement and
      # subscription. The durable terminal summary closes that race.
      case RunStore.fetch(run_id) do
        {:ok, %{summary: summary}} when is_map(summary) ->
          Bus.unsubscribe(Bus.run_topic(run_id))
          {:reply, :ok, state}

        _ ->
          {:reply, :ok, add_run(state, run_id, owner, opts)}
      end
    end
  end

  def handle_call({:stop_run, run_id}, _from, state) do
    {:reply, :ok, remove_run(state, run_id)}
  end

  def handle_call({:stop_session, session_key}, _from, state) do
    state =
      Enum.reduce(state.runs, state, fn {run_id, run}, acc ->
        if run.session_key == session_key, do: remove_run(acc, run_id), else: acc
      end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(%Event{type: :run_completed, meta: meta}, state) do
    run_id = (meta || %{})[:run_id] || (meta || %{})["run_id"]
    {:noreply, remove_run(state, run_id)}
  end

  def handle_info({:refresh, target, token}, state) do
    case state.targets[target] do
      %{token: ^token} = entry ->
        entry = maybe_send(entry)
        timer = Process.send_after(self(), {:refresh, target, token}, entry.interval_ms)
        {:noreply, put_in(state.targets[target], %{entry | timer: timer})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:cap, target, token}, state) do
    case state.targets[target] do
      %{token: ^token, runs: runs} ->
        {:noreply, Enum.reduce(runs, state, &remove_run(&2, &1))}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state =
      Enum.reduce(state.targets, state, fn {target, entry}, acc ->
        cond do
          entry.owner_ref == ref -> Enum.reduce(entry.runs, acc, &remove_run(&2, &1))
          match?({_pid, ^ref}, entry.worker) -> put_in(acc.targets[target].worker, nil)
          true -> acc
        end
      end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.targets, fn {_target, entry} -> release(entry) end)
  end

  defp add_run(state, run_id, owner, opts) do
    target = Keyword.fetch!(opts, :target)

    entry =
      case state.targets[target] do
        nil ->
          token = make_ref()
          send(self(), {:refresh, target, token})

          %{
            token: token,
            owner_ref: Process.monitor(owner),
            send: Keyword.fetch!(opts, :send),
            interval_ms: Keyword.fetch!(opts, :interval_ms),
            cap:
              Process.send_after(
                self(),
                {:cap, target, token},
                Keyword.get(opts, :cap_ms, @default_cap_ms)
              ),
            timer: nil,
            worker: nil,
            runs: MapSet.new([run_id])
          }

        entry ->
          %{entry | runs: MapSet.put(entry.runs, run_id)}
      end

    state
    |> put_in([:targets, target], entry)
    |> put_in([:runs, run_id], %{target: target, session_key: Keyword.get(opts, :session_key)})
  end

  defp remove_run(state, run_id) do
    case Map.pop(state.runs, run_id) do
      {nil, _} ->
        state

      {%{target: target}, runs} ->
        Bus.unsubscribe(Bus.run_topic(run_id))
        entry = state.targets[target]
        remaining = MapSet.delete(entry.runs, run_id)

        if MapSet.size(remaining) == 0 do
          release(entry)
          %{state | runs: runs, targets: Map.delete(state.targets, target)}
        else
          %{
            state
            | runs: runs,
              targets: Map.put(state.targets, target, %{entry | runs: remaining})
          }
        end
    end
  end

  defp release(entry) do
    if entry.timer, do: Process.cancel_timer(entry.timer)
    Process.cancel_timer(entry.cap)
    Process.demonitor(entry.owner_ref, [:flush])

    if entry.worker do
      {pid, ref} = entry.worker
      Process.exit(pid, :kill)
      Process.demonitor(ref, [:flush])
    end
  end

  defp maybe_send(%{worker: nil} = entry) do
    worker =
      spawn_monitor(fn ->
        try do
          case entry.send.() do
            :ok -> :ok
            {:ok} -> :ok
            {:ok, _} -> :ok
            _ -> Logger.debug("typing indicator send failed")
          end
        rescue
          _ -> Logger.debug("typing indicator send failed")
        catch
          _, _ -> Logger.debug("typing indicator send failed")
        end
      end)

    %{entry | worker: worker}
  end

  defp maybe_send(entry), do: entry

  defp best_effort(fun) do
    fun.()
  rescue
    _ -> Logger.debug("typing indicator lifecycle unavailable")
  catch
    :exit, _ -> Logger.debug("typing indicator lifecycle unavailable")
  end
end
