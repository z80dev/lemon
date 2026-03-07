defmodule LemonControlPlane.TalkModeStore do
  @moduledoc """
  Typed wrapper for session talk-mode settings.
  """

  alias LemonCore.Store

  @table :talk_mode

  @spec get(binary()) :: map() | nil
  def get(session_key) when is_binary(session_key), do: Store.get(@table, session_key)

  @spec put(binary(), map()) :: :ok
  def put(session_key, config) when is_binary(session_key) and is_map(config),
    do: Store.put(@table, session_key, config)
end
