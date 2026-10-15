defmodule LemonControlPlane.Methods.SetupStatus do
  @moduledoc """
  Read-only, content-free first-run readiness for connected clients.

  Wraps `LemonCore.Setup.Readiness` without exposing config paths, provider or
  model names, credential values, secret references or diagnostic errors.
  Pending steps contain only fixed ids, labels and local recovery commands.
  """

  @behaviour LemonControlPlane.Method

  alias LemonCore.Setup.Readiness

  @impl true
  def name, do: "setup.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    status_fun =
      Application.get_env(:lemon_control_plane, :setup_status_fun, &Readiness.status/0)

    state = status_fun.()

    {:ok,
     %{
       "ready" => Readiness.ready?(state),
       "pendingSteps" => Enum.map(Readiness.pending_steps(state), &project_step/1)
     }}
  end

  defp project_step(:config),
    do: %{"id" => "config", "label" => "Create configuration", "command" => "lemon setup"}

  defp project_step(:secrets),
    do: %{"id" => "secrets", "label" => "Configure secrets", "command" => "lemon setup"}

  defp project_step(:provider),
    do: %{
      "id" => "provider",
      "label" => "Choose a default provider and model with usable credentials",
      "command" => "lemon setup provider"
    }
end
