defmodule LemonGateway.Config do
  @moduledoc """
  Centralized configuration for LemonGateway.

  Loads configuration from the canonical Lemon TOML config (via ConfigLoader).
  """
  use GenServer

  alias LemonGateway.ConfigLoader

  @default %{
    max_concurrent_runs: 2,
    default_cwd: nil,
    auto_resume: false,
    enable_telegram: false,
    enable_discord: false,
    enable_xmtp: false,
    enable_webhook: false,
    projects: %{},
    bindings: [],
    email: %{},
    xmtp: %{},
    webhook: %{}
  }

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  A full-replacement config map held in app env, if one is set.

  Embedders and tests can put a complete config under
  `config :lemon_gateway, LemonGateway.Config, %{...}` to bypass the canonical
  loader. Exposed for `LemonCore.EngineInfoBridge`, so callers outside this app
  read it through the bridge instead of reaching into our app env.
  """
  @spec replacement_config() :: map() | keyword() | nil
  def replacement_config, do: Application.get_env(:lemon_gateway, __MODULE__)

  @doc "Returns the full configuration map."
  @spec get() :: map()
  def get, do: GenServer.call(__MODULE__, :get)

  @doc "Returns the value for a specific configuration key."
  @spec get(atom()) :: term()
  def get(key), do: GenServer.call(__MODULE__, {:get, key})

  @doc "Reads runtime config, falling back to application environment before startup."
  @spec get_or_env(atom(), term()) :: term()
  def get_or_env(key, default \\ nil) do
    if is_pid(Process.whereis(__MODULE__)) do
      case get(key) do
        nil -> default
        value -> value
      end
    else
      fallback = Application.get_env(:lemon_gateway, key, default)

      case replacement_config() do
        cfg when is_map(cfg) -> LemonCore.GatewayConfig.fetch(cfg, key, fallback)
        cfg when is_list(cfg) -> Keyword.get(cfg, key, fallback)
        _ -> fallback
      end
    end
  end

  @doc """
  Returns all configured projects as a map of project_id => Project struct.
  """
  @spec get_projects() :: %{String.t() => LemonGateway.Project.t()}
  def get_projects, do: GenServer.call(__MODULE__, {:get, :projects}) || %{}

  @doc """
  Returns all configured bindings as a list of Binding structs.
  """
  @spec get_bindings() :: [LemonCore.Binding.t()]
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
