defmodule LemonGateway.Run do
  @moduledoc false
  use GenServer

  alias LemonGateway.Event
  alias LemonGateway.Types.Job

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init(%{job: %Job{} = job, slot_ref: slot_ref, worker_pid: worker_pid} = args) do
    state = %{
      job: job,
      slot_ref: slot_ref,
      worker_pid: worker_pid,
      engine: nil,
      run_ref: nil,
      cancel_ctx: nil
    }

    {:ok, state, {:continue, {:start_run, args}}}
  end

  @impl true
  def handle_continue({:start_run, %{job: job}}, state) do
    engine_id = engine_id_for(job)
    engine = LemonGateway.EngineRegistry.get_engine!(engine_id)

    case engine.start_run(job, %{}, self()) do
      {:ok, run_ref, cancel_ctx} ->
        {:noreply, %{state | engine: engine, run_ref: run_ref, cancel_ctx: cancel_ctx}}

      {:error, reason} ->
        completed = %Event.Completed{engine: engine_id, ok: false, error: reason, answer: ""}
        finalize(state, completed)
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info({:engine_event, run_ref, event}, %{run_ref: run_ref} = state) do
    LemonGateway.Store.append_run_event(run_ref, event)

    case event do
      %Event.Completed{} = completed ->
        finalize(state, completed)
        {:stop, :normal, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp engine_id_for(%Job{resume: %LemonGateway.Types.ResumeToken{engine: engine}}), do: engine

  defp engine_id_for(%Job{engine_hint: engine_hint}) when is_binary(engine_hint), do: engine_hint

  defp engine_id_for(_job), do: LemonGateway.Config.get(:default_engine)

  defp finalize(state, %Event.Completed{} = completed) do
    LemonGateway.Store.finalize_run(state.run_ref, %{completed: completed})
    LemonGateway.Scheduler.release_slot(state.slot_ref)
    send(state.worker_pid, {:run_complete, self(), completed})

    notify_pid = state.job.meta && state.job.meta[:notify_pid]

    if is_pid(notify_pid) do
      send(notify_pid, {:lemon_gateway_run_completed, state.job, completed})
    end
  end
end
