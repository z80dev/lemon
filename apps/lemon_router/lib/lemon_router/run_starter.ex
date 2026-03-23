defmodule LemonRouter.RunStarter do
  @moduledoc """
  Starts a prepared router submission under the configured run supervisor.

  This module owns only run-start mechanics for `%LemonRouter.Submission{}`.
  It does not own queue semantics, router phase emission, or session registry
  state.
  """

  alias LemonRouter.Submission

  @spec start(Submission.t(), pid(), term()) :: {:ok, pid()} | {:error, term()}
  def start(%Submission{} = submission, coordinator_pid, conversation_key)
      when is_pid(coordinator_pid) do
    run_opts =
      submission.run_process_opts
      |> Map.merge(%{
        run_id: submission.run_id,
        session_key: submission.session_key,
        queue_mode: submission.queue_mode,
        execution_request: submission.execution_request,
        coordinator_pid: coordinator_pid,
        conversation_key: conversation_key,
        manage_session_registry?: false
      })

    spec = {submission.run_process_module, run_opts}

    case start_child(submission.run_supervisor, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, :max_children} ->
        {:error, :run_capacity_reached}

      {:error, {:noproc, _}} ->
        {:error, :router_not_ready}

      {:error, :noproc} ->
        {:error, :router_not_ready}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_child(run_supervisor, spec) do
    DynamicSupervisor.start_child(run_supervisor, spec)
  catch
    :exit, {:noproc, _detail} ->
      {:error, :noproc}

    :exit, :noproc ->
      {:error, :noproc}
  end
end
