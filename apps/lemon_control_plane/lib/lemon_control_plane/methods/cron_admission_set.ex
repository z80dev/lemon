defmodule LemonControlPlane.Methods.CronAdmissionSet do
  @moduledoc "Write-only provisioning of a dedicated encrypted cron admission token."

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "cron.admission.set"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) when is_map(params) do
    case LemonAutomation.CronAdmission.set_token(params["routineId"], params["token"]) do
      {:ok, secret_name} ->
        {:ok, %{"secretName" => secret_name, "set" => true}}

      {:error, :invalid_request} ->
        {:error, {:invalid_request, "Invalid admission credential request", nil}}

      {:error, :secret_unavailable} ->
        {:error, {:internal_error, "Admission credential storage unavailable", nil}}
    end
  end

  def handle(_params, _ctx),
    do: {:error, {:invalid_request, "Invalid admission credential request", nil}}
end
