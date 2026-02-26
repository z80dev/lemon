defmodule CodingAgent.Wasm.SidecarSupervisor do
  @moduledoc """
  Dynamic supervisor for per-session WASM sidecar processes.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_sidecar(keyword()) :: DynamicSupervisor.on_start_child()
  def start_sidecar(opts) do
    session_id = Keyword.get(opts, :session_id, System.unique_integer([:positive]))

    child_spec = %{
      id: {CodingAgent.Wasm.SidecarSession, session_id},
      start: {CodingAgent.Wasm.SidecarSession, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @spec stop_sidecar(pid()) :: :ok | {:error, term()}
  def stop_sidecar(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end
