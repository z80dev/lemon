defmodule LemonControlPlane.VoicewakeStore do
  @moduledoc """
  Typed wrapper for control-plane voicewake configuration.
  """

  alias LemonCore.Store

  @table :voicewake_config

  @spec get() :: map() | nil
  def get, do: Store.get(@table, :global)

  @spec put(map()) :: :ok
  def put(config) when is_map(config), do: Store.put(@table, :global, config)
end
