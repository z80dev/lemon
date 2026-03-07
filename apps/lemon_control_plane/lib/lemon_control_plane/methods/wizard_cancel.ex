defmodule LemonControlPlane.Methods.WizardCancel do
  @moduledoc """
  Handler for the wizard.cancel control plane method.

  Cancels an in-progress wizard.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.WizardStore
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "wizard.cancel"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    wizard_id = params["wizardId"]

    if is_nil(wizard_id) or wizard_id == "" do
      {:error, Errors.invalid_request("wizardId is required")}
    else
      case WizardStore.get(wizard_id) do
        nil ->
          {:error, Errors.not_found("Wizard not found")}

        wizard ->
          if wizard.status != :in_progress do
            {:error, Errors.conflict("Wizard is not in progress")}
          else
            updated =
              Map.merge(wizard, %{
                status: :cancelled,
                cancelled_at_ms: System.system_time(:millisecond)
              })

            WizardStore.put(wizard_id, updated)

            {:ok, %{"success" => true}}
          end
      end
    end
  end
end
