defmodule LemonRouter.EngineSessionClaim do
  @moduledoc """
  Fail-fast ownership of an engine session by the calling `RunProcess`.

  Claims are `LemonRouter.EngineSessionRegistry` names, so owner death releases
  them automatically.
  """

  @registry LemonRouter.EngineSessionRegistry

  @spec claim(term()) :: :ok | {:error, :session_in_use}
  def claim(key) do
    case Registry.register(@registry, key, nil) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> {:error, :session_in_use}
    end
  end

  @spec release(term()) :: :ok
  def release(key), do: Registry.unregister(@registry, key)
end
