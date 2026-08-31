defmodule LemonControlPlane.Methods.CommandsCatalog do
  @moduledoc """
  Read-only discovery handler for Lemon's portable slash-command catalog.

  Execution remains owned by the consuming channel or interactive client and
  the runtime subsystem named by each command capability.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "commands.catalog"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    {:ok,
     %{
       "commands" => LemonChannels.CommandCatalog.catalog(),
       "categories" => LemonChannels.CommandCatalog.categories(),
       "summary" => LemonChannels.CommandCatalog.summary()
     }}
  end
end
