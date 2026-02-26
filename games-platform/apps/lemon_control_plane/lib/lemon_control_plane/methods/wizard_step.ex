defmodule LemonControlPlane.Methods.WizardStep do
  @moduledoc """
  Handler for the wizard.step control plane method.

  Advances or navigates within a wizard.
  """

  @behaviour LemonControlPlane.Method

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
        case LemonCore.Store.get(:wizards, wizard_id) do
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
                updated = %{wizard |
                  current_step: step_index,
                  data: Map.merge(wizard.data, data),
                  updated_at_ms: System.system_time(:millisecond)
                }

                # Check if wizard is complete
                is_complete = step_id == "complete" or step_index == length(wizard.steps) - 1

                updated =
                  if is_complete do
                    Map.put(updated, :status, :completed)
                  else
                    updated
                  end

                LemonCore.Store.put(:wizards, wizard_id, updated)

                {:ok, %{
                  "wizardId" => wizard_id,
                  "currentStep" => step_index,
                  "stepId" => step_id,
                  "complete" => is_complete,
                  "data" => updated.data
                }}
              end
            end
        end
    end
  end
end
