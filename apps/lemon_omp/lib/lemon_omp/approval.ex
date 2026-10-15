defmodule LemonOmp.Approval do
  @moduledoc false

  alias LemonCore.ExecApprovals

  # The Session owns the dialog, but never waits for the operator. A separate
  # guardian covers brutal Session death and cancellation before registration:
  # only after the waiter is dead can its pending row be definitively cancelled.
  def start(owner, dialog_id, params) do
    spawn_link(fn ->
      waiter = self()
      spawn(fn -> guard(owner, waiter, params.approval_id) end)
      result = ExecApprovals.request(params)
      send(owner, {:approval_result, dialog_id, params.approval_id, result})
    end)
  end

  def cancel(waiter, approval_id, reason) do
    ref = Process.monitor(waiter)
    Process.exit(waiter, :kill)

    receive do
      {:DOWN, ^ref, :process, ^waiter, _reason} -> :ok
    end

    _ = ExecApprovals.cancel(approval_id, reason)
    :ok
  end

  defp guard(owner, waiter, approval_id) do
    owner_ref = Process.monitor(owner)
    waiter_ref = Process.monitor(waiter)

    receive do
      {:DOWN, ^owner_ref, :process, _pid, _reason} ->
        Process.exit(waiter, :kill)

        receive do
          {:DOWN, ^waiter_ref, :process, _pid, _reason} -> :ok
        end

      {:DOWN, ^waiter_ref, :process, _pid, _reason} ->
        Process.demonitor(owner_ref, [:flush])
    end

    _ = ExecApprovals.cancel(approval_id, "omp approval dialog ended")
  end
end
