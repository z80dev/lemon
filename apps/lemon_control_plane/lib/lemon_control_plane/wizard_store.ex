defmodule LemonControlPlane.WizardStore do
  @moduledoc """
  Typed wrapper for control-plane wizard sessions.
  """

  alias LemonCore.Store

  @table :wizards

  @spec get(binary()) :: map() | nil
  def get(wizard_id) when is_binary(wizard_id), do: Store.get(@table, wizard_id)

  @spec put(binary(), map()) :: :ok
  def put(wizard_id, wizard) when is_binary(wizard_id) and is_map(wizard),
    do: Store.put(@table, wizard_id, wizard)
end
