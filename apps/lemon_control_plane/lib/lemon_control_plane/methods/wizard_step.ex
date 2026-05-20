defmodule LemonControlPlane.Methods.WizardStep do
  @moduledoc """
  Handler for the wizard.step control plane method.

  Advances or navigates within a wizard.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.WizardStore
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "wizard.step"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    wizard_id = params["wizardId"]
    step_id = params["stepId"]
    data = params["data"] || %{}

    cond do
      is_nil(wizard_id) or wizard_id == "" ->
        {:error, Errors.invalid_request("wizardId is required")}

      is_nil(step_id) or step_id == "" ->
        {:error, Errors.invalid_request("stepId is required")}

      true ->
        case WizardStore.get(wizard_id) do
          nil ->
            {:error, Errors.not_found("Wizard not found")}

          wizard ->
            if wizard.status != :in_progress do
              {:error, Errors.conflict("Wizard is not in progress")}
            else
              # Find step index
              step_index = Enum.find_index(wizard.steps, &(&1["id"] == step_id))

              if is_nil(step_index) do
                {:error, Errors.not_found("Step not found")}
              else
                # Merge data and update wizard
                updated =
                  %{
                    wizard
                    | current_step: step_index,
                      data: Map.merge(wizard.data, data)
                  }
                  |> Map.put(:updated_at_ms, System.system_time(:millisecond))

                # Check if wizard is complete
                is_complete = step_id == "complete" or step_index == length(wizard.steps) - 1

                updated =
                  if is_complete do
                    Map.put(updated, :status, :completed)
                  else
                    updated
                  end

                WizardStore.put(wizard_id, updated)

                {:ok,
                 %{
                   "wizardId" => wizard_id,
                   "currentStep" => step_index,
                   "stepId" => step_id,
                   "complete" => is_complete,
                   "data" => redact_data(updated.data),
                   "summary" => %{
                     "action" => name(),
                     "wizardIdReturned" => true,
                     "stepIdReturned" => true,
                     "currentStep" => step_index,
                     "complete" => is_complete,
                     "dataKeyCount" => map_size(updated.data),
                     "cleanup" => %{
                       "includesWizardData" => map_size(updated.data) > 0,
                       "includesSecretValues" => false,
                       "includesCredentialValues" => false
                     }
                   }
                 }}
              end
            end
        end
    end
  end

  defp redact_data(data) when is_map(data) do
    Map.new(data, fn {key, value} ->
      if sensitive_key?(key) do
        {key, %{"redacted" => true, "kind" => "secret"}}
      else
        {key, redact_data(value)}
      end
    end)
  end

  defp redact_data(data) when is_list(data), do: Enum.map(data, &redact_data/1)

  defp redact_data(data), do: data

  defp sensitive_key?(key) do
    normalized = key |> to_string() |> String.downcase()

    Enum.any?(
      ["api_key", "apikey", "secret", "token", "password", "private_key", "credential"],
      &String.contains?(normalized, &1)
    )
  end
end
