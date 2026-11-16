defmodule LemonGateway.EngineSessionClaim do
  @moduledoc """
  Fail-fast ownership of an engine session by the calling Run process.

  Claims use RunRegistry names, so owner death releases them automatically.
  """

  @spec claim(term()) :: :ok | {:error, :session_in_use}
  def claim(key) do
    case Registry.register(LemonGateway.RunRegistry, {:engine_session, key}, nil) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> {:error, :session_in_use}
    end
  end

  @spec release(term()) :: :ok
  def release(key) do
    Registry.unregister(LemonGateway.RunRegistry, {:engine_session, key})
  end
end
