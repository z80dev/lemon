defmodule LemonControlPlane.Lifecycle do
  @moduledoc """
  Single-flight runtime lifecycle actions. Acceptance reserves an action, but it
  is armed only when the WebSocket has returned its reply to the transport.
  """

  use GenServer
  require Logger

  @delay_ms 250

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def request(action, %{conn_pid: pid} = ctx) when action in [:restart, :stop] and is_pid(pid) do
    GenServer.call(__MODULE__, {:request, action, pid, Map.get(ctx, :conn_id)})
  catch
    :exit, _ -> {:error, {:unavailable, "Runtime lifecycle coordinator is unavailable."}}
  end

  def request(_, _),
    do: {:error, {:unavailable, "Runtime lifecycle actions require a WebSocket connection."}}

  # Called by the same socket process on its next mailbox turn, after the
  # previous callback's {:push, ...} has been written by WebSock/Bandit.
  def after_reply(ref), do: GenServer.cast(__MODULE__, {:after_reply, ref, self()})

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_call({:request, _action, _pid, _conn_id}, _from, state) when not is_nil(state) do
    {:reply, {:error, {:conflict, "A runtime lifecycle action is already in flight."}}, state}
  end

  def handle_call({:request, action, pid, conn_id}, _from, nil) do
    availability = availability()

    if availability[Atom.to_string(action)] do
      ref = make_ref()
      accepted_at = System.system_time(:millisecond)
      monitor = Process.monitor(pid)

      state = %{
        ref: ref,
        action: action,
        conn_pid: pid,
        monitor: monitor,
        armed: false,
        driver:
          Application.get_env(
            :lemon_control_plane,
            :lifecycle_driver,
            LemonControlPlane.Lifecycle.Driver
          )
      }

      Logger.warning("Runtime lifecycle action accepted",
        action: action,
        conn_id: conn_id,
        accepted_at_ms: accepted_at
      )

      send(pid, {:lifecycle_after_reply, ref})

      {:reply,
       {:ok,
        %{"accepted" => true, "action" => Atom.to_string(action), "acceptedAtMs" => accepted_at}},
       state}
    else
      {:reply, {:error, {:unavailable, availability["reason"]}}, nil}
    end
  end

  @impl true
  def handle_cast({:after_reply, ref, pid}, %{ref: ref, conn_pid: pid, armed: false} = state) do
    Process.demonitor(state.monitor, [:flush])
    Process.send_after(self(), {:perform, ref}, @delay_ms)
    {:noreply, %{state | armed: true}}
  end

  def handle_cast({:after_reply, _, _}, state), do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor, armed: false}) do
    Logger.warning("Runtime lifecycle acceptance cancelled before reply delivery")
    {:noreply, nil}
  end

  def handle_info({:perform, ref}, %{ref: ref, armed: true} = state) do
    result =
      try do
        case state.action do
          :restart -> state.driver.restart(LemonControlPlane.Lifecycle.Driver.restart_command())
          :stop -> state.driver.stop()
        end
      rescue
        _ -> {:error, :lifecycle_failed}
      catch
        _, _ -> {:error, :lifecycle_failed}
      end

    if result == :ok do
      Logger.warning("Runtime lifecycle action dispatched", action: state.action)
      {:noreply, state}
    else
      Logger.error("Runtime lifecycle action could not be dispatched", action: state.action)
      {:noreply, nil}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  def availability do
    managed? = launcher() != nil

    %{
      "restart" => managed?,
      "stop" => true,
      "reason" =>
        if(managed?,
          do: nil,
          else: "Restart requires a launcher-managed runtime (LEMON_LAUNCHER)."
        )
    }
  end

  @doc false
  def launcher do
    case System.get_env("LEMON_LAUNCHER") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          value -> value
        end

      _ ->
        nil
    end
  end
end
