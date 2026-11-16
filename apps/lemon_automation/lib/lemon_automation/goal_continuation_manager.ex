defmodule LemonAutomation.GoalContinuationManager do
  @moduledoc false

  use GenServer

  alias LemonAutomation.GoalLoopManager

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def continue_once(session_key, opts \\ []) do
    GenServer.call(
      __MODULE__,
      {:continue_once, session_key, opts},
      GoalLoopManager.call_timeout(Keyword.put(opts, :await_completion, true)) + 1_000
    )
  end

  @impl true
  def init(_opts), do: {:ok, %{calls: %{}}}

  @impl true
  def handle_call({:continue_once, session_key, opts}, from, state) do
    case LemonCore.TaskSupervisor.async_nolink(LemonAutomation.TaskSupervisor, fn ->
           GoalLoopManager.run_once(session_key, Keyword.put(opts, :verdict, :continue))
         end) do
      {:ok, task} -> {:noreply, put_in(state.calls[task.ref], from)}
      {:error, _reason} = error -> {:reply, error, state}
    end
  rescue
    error -> {:reply, {:error, error}, state}
  end

  @impl true
  def handle_info({ref, result}, state) do
    Process.demonitor(ref, [:flush])

    case pop_in(state.calls[ref]) do
      {nil, state} ->
        {:noreply, state}

      {from, state} ->
        GenServer.reply(from, result)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case pop_in(state.calls[ref]) do
      {nil, state} ->
        {:noreply, state}

      {from, state} ->
        GenServer.reply(from, {:error, :continuation_task_down})
        {:noreply, state}
    end
  end
end
