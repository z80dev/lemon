defmodule LemonControlPlane.Methods.SystemRestart do
  @moduledoc "Accept a launcher-managed restart after the admin reply is flushed."
  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "system.restart"
  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, ctx) when params == %{} or is_nil(params),
    do: LemonControlPlane.Lifecycle.request(:restart, ctx)

  def handle(_, _), do: {:error, {:invalid_request, "system.restart expects an empty object."}}
end
