defmodule LemonControlPlane.Methods.WizardStart do
  @moduledoc """
  Handler for the wizard.start control plane method.

  Starts a setup/configuration wizard.
  """

  @behaviour LemonControlPlane.Method

  alias LemonCore.Id

  @impl true
  def name, do: "wizard.start"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    wizard_type = params["wizardId"] || "setup"

    wizard_id = Id.uuid()

    wizard = %{
      id: wizard_id,
      type: wizard_type,
      current_step: 0,
      steps: get_wizard_steps(wizard_type),
      data: %{},
      status: :in_progress,
      started_at_ms: System.system_time(:millisecond)
    }

    LemonCore.Store.put(:wizards, wizard_id, wizard)

    {:ok, %{
      "wizardId" => wizard_id,
      "type" => wizard_type,
      "steps" => wizard.steps,
      "currentStep" => 0
    }}
  end

  defp get_wizard_steps("setup") do
    [
      %{"id" => "welcome", "title" => "Welcome", "description" => "Welcome to Lemon setup"},
      %{"id" => "api_keys", "title" => "API Keys", "description" => "Configure your API keys"},
      %{"id" => "channels", "title" => "Channels", "description" => "Set up messaging channels"},
      %{"id" => "complete", "title" => "Complete", "description" => "Setup complete"}
    ]
  end

  defp get_wizard_steps("channel") do
    [
      %{"id" => "select", "title" => "Select Channel", "description" => "Choose a channel type"},
      %{"id" => "configure", "title" => "Configure", "description" => "Enter channel settings"},
      %{"id" => "test", "title" => "Test", "description" => "Test the connection"},
      %{"id" => "complete", "title" => "Complete", "description" => "Channel setup complete"}
    ]
  end

  defp get_wizard_steps(_) do
    [
      %{"id" => "start", "title" => "Start", "description" => "Begin wizard"},
      %{"id" => "complete", "title" => "Complete", "description" => "Wizard complete"}
    ]
  end
end
