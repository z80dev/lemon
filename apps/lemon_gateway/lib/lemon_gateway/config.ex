defmodule LemonGateway.Config do
  @moduledoc """
  Centralized configuration for LemonGateway.

  Loads configuration from TOML file (via ConfigLoader) with fallback to Application env.
  """
  use GenServer

  alias LemonGateway.ConfigLoader

  @default %{
    max_concurrent_runs: 2,
    default_engine: "lemon",
    auto_resume: false,
    enable_telegram: false,
    require_engine_lock: true,
    engine_lock_timeout_ms: 60_000,
    projects: %{},
    bindings: []
  }

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec get() :: map()
  def get, do: GenServer.call(__MODULE__, :get)

  @spec get(atom()) :: term()
  def get(key), do: GenServer.call(__MODULE__, {:get, key})

  @doc """
  Returns all configured projects as a map of project_id => Project struct.
  """
  @spec get_projects() :: %{String.t() => LemonGateway.Project.t()}
  def get_projects, do: GenServer.call(__MODULE__, {:get, :projects}) || %{}

  @doc """
  Returns all configured bindings as a list of Binding structs.
  """
  @spec get_bindings() :: [LemonGateway.Binding.t()]
  def get_bindings, do: GenServer.call(__MODULE__, {:get, :bindings}) || []

  @impl true
  def init(_opts) do
    cfg = ConfigLoader.load()
    {:ok, Map.merge(@default, cfg)}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  def handle_call({:get, key}, _from, state), do: {:reply, Map.get(state, key), state}
end
