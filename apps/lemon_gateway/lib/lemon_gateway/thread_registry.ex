defmodule LemonGateway.ThreadRegistry do
  @moduledoc false

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(_opts) do
    Registry.start_link(keys: :unique, name: __MODULE__)
  end

  @spec whereis(term()) :: pid() | nil
  def whereis(thread_key) do
    case Registry.lookup(__MODULE__, thread_key) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  @spec register(term()) :: {:ok, pid()} | {:error, {:already_registered, pid()}}
  def register(thread_key) do
    case Registry.register(__MODULE__, thread_key, :ok) do
      {:ok, _pid} -> {:ok, self()}
      {:error, {:already_registered, pid}} -> {:error, {:already_registered, pid}}
    end
  end
end
