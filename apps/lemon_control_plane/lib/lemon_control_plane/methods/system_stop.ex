defmodule LemonControlPlane.Methods.SystemStop do
  @moduledoc "Accept a graceful VM stop after the admin reply is flushed."
  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "system.stop"
  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, ctx) when params == %{} or is_nil(params),
    do: LemonControlPlane.Lifecycle.request(:stop, ctx)

  def handle(_, _), do: {:error, {:invalid_request, "system.stop expects an empty object."}}
end
