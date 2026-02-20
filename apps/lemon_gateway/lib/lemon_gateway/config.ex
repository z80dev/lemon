defmodule LemonGateway.Config do
  @moduledoc """
  Centralized configuration for LemonGateway.

  Loads configuration from the canonical Lemon TOML config (via ConfigLoader).
  """
  use GenServer

  alias LemonGateway.ConfigLoader

  @default %{
    max_concurrent_runs: 2,
    default_engine: "lemon",
    default_cwd: nil,
    auto_resume: false,
    enable_telegram: false,
    enable_discord: false,
    enable_farcaster: false,
    enable_email: false,
    require_engine_lock: true,
    engine_lock_timeout_ms: 60_000,
    projects: %{},
    bindings: [],
    farcaster: %{},
    email: %{}
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

  @doc """
  Returns the queue configuration (cap, drop policy).
  """
  @spec get_queue_config() :: %{
          cap: non_neg_integer() | nil,
          drop: :oldest | :newest | nil,
          mode: atom() | nil
        }
  def get_queue_config,
    do: GenServer.call(__MODULE__, {:get, :queue}) || %{cap: nil, drop: nil, mode: nil}

  @impl true
  def init(_opts) do
    cfg = ConfigLoader.load()
    {:ok, Map.merge(@default, cfg)}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  def handle_call({:get, key}, _from, state), do: {:reply, Map.get(state, key), state}
end
