defmodule CodingAgent.SessionSupervisor do
  @moduledoc false

  use DynamicSupervisor

  @type start_opts :: keyword()

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_session(start_opts()) :: DynamicSupervisor.on_start_child()
  def start_session(opts) do
    opts = Keyword.put_new(opts, :register, true)
    child_id = Keyword.get(opts, :session_id) || make_ref()

    child_spec = %{
      id: {CodingAgent.Session, child_id},
      start: {CodingAgent.Session, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @spec stop_session(pid() | String.t()) :: :ok | {:error, term()}
  def stop_session(session) when is_pid(session) do
    DynamicSupervisor.terminate_child(__MODULE__, session)
  end

  def stop_session(session_id) when is_binary(session_id) do
    case CodingAgent.SessionRegistry.lookup(session_id) do
      {:ok, pid} -> stop_session(pid)
      :error -> {:error, :not_found}
    end
  end

  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(session_id) when is_binary(session_id) do
    CodingAgent.SessionRegistry.lookup(session_id)
  end

  @spec list_sessions() :: [pid()]
  def list_sessions do
    if Process.whereis(__MODULE__) do
      DynamicSupervisor.which_children(__MODULE__)
      |> Enum.flat_map(fn
        {_id, pid, :worker, _modules} when is_pid(pid) -> [pid]
        _ -> []
      end)
    else
      []
    end
  end
end
