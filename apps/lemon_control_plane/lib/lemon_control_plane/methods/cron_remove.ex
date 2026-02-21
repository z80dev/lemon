defmodule LemonControlPlane.Methods.CronRemove do
  @moduledoc """
  Handler for the cron.remove method.

  Removes a cron job.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "cron.remove"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    with {:ok, job_id} <- LemonControlPlane.Method.require_param(params, "id") do
      case LemonAutomation.CronManager.remove(job_id) do
        :ok ->
          {:ok, %{"removed" => true, "id" => job_id}}

        {:error, :not_found} ->
          {:error, {:not_found, "Cron job not found: #{job_id}", nil}}

        {:error, reason} ->
          {:error, {:internal_error, inspect(reason), nil}}
      end
    end
  end
end
