defmodule LemonControlPlane.Methods.CronUpdate do
  @moduledoc """
  Handler for the cron.update method.

  Updates an existing cron job.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "cron.update"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    with {:ok, job_id} <- LemonControlPlane.Method.require_param(params, "id") do
      patch = build_patch(params)

      case LemonAutomation.CronManager.update(job_id, patch) do
        {:ok, job} ->
          {:ok, %{
            "id" => job.id,
            "updated" => true,
            "nextRunAtMs" => job.next_run_at_ms
          }}

        {:error, :not_found} ->
          {:error, {:not_found, "Cron job not found: #{job_id}", nil}}

        {:error, reason} ->
          {:error, {:internal_error, inspect(reason), nil}}
      end
    end
  end

  defp build_patch(params) do
    %{}
    |> maybe_put(:name, params["name"])
    |> maybe_put(:schedule, params["schedule"])
    |> maybe_put(:enabled, params["enabled"])
    |> maybe_put(:prompt, params["prompt"])
    |> maybe_put(:timezone, params["timezone"])
    |> maybe_put(:jitter_sec, params["jitterSec"])
    |> maybe_put(:timeout_ms, params["timeoutMs"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
