defmodule LemonChannels.Registry do
  @moduledoc """
  Registry for channel plugins.

  Manages registration and lookup of channel plugins.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a channel plugin.
  """
  @spec register(module()) :: :ok | {:error, term()}
  def register(plugin_module) do
    GenServer.call(__MODULE__, {:register, plugin_module})
  end

  @doc """
  Unregister a channel plugin.
  """
  @spec unregister(binary()) :: :ok
  def unregister(plugin_id) do
    GenServer.call(__MODULE__, {:unregister, plugin_id})
  end

  @doc """
  Get a plugin by ID.
  """
  @spec get_plugin(binary()) :: module() | nil
  def get_plugin(plugin_id) do
    GenServer.call(__MODULE__, {:get, plugin_id})
  end

  @doc """
  List all registered plugins.
  """
  @spec list_plugins() :: [module()]
  def list_plugins do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  List adapters with metadata for status UIs.

  Returns a list of `{channel_id, info}` tuples.
  """
  @spec list() :: [{binary(), map()}]
  def list do
    GenServer.call(__MODULE__, :list_info)
  end

  @doc """
  Summarize configured/connected channel adapters.
  """
  @spec status() :: %{configured: [binary()], connected: [binary()]}
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Stop and unregister a channel adapter by `channel_id`.
  """
  @spec logout(binary()) :: :ok | {:error, :not_found} | {:error, term()}
  def logout(channel_id) when is_binary(channel_id) do
    GenServer.call(__MODULE__, {:logout, channel_id})
  end

  @doc """
  Get plugin metadata.
  """
  @spec get_meta(binary()) :: map() | nil
  def get_meta(plugin_id) do
    case get_plugin(plugin_id) do
      nil -> nil
      plugin -> plugin.meta()
    end
  end

  @doc """
  Get plugin capabilities.
  """
  @spec get_capabilities(binary()) :: map() | nil
  def get_capabilities(plugin_id) do
    case get_meta(plugin_id) do
      nil -> nil
      meta -> Map.get(meta, :capabilities, %{})
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{plugins: %{}}}
  end

  @impl true
  def handle_call({:register, plugin_module}, _from, state) do
    plugin_id = plugin_module.id()

    if Map.has_key?(state.plugins, plugin_id) do
      {:reply, {:error, :already_registered}, state}
    else
      plugins = Map.put(state.plugins, plugin_id, plugin_module)
      {:reply, :ok, %{state | plugins: plugins}}
    end
  end

  def handle_call({:unregister, plugin_id}, _from, state) do
    plugins = Map.delete(state.plugins, plugin_id)
    {:reply, :ok, %{state | plugins: plugins}}
  end

  def handle_call({:get, plugin_id}, _from, state) do
    plugin = Map.get(state.plugins, plugin_id)
    {:reply, plugin, state}
  end

  def handle_call(:list, _from, state) do
    plugins = Map.values(state.plugins)
    {:reply, plugins, state}
  end

  def handle_call(:list_info, _from, state) do
    plugins = Map.values(state.plugins)

    result =
      Enum.map(plugins, fn plugin ->
        id = plugin.id()
        meta = plugin.meta() || %{}

        info = %{
          type: id,
          status: if(adapter_running?(plugin), do: :running, else: :stopped),
          account_id: nil,
          capabilities: meta[:capabilities] || %{}
        }

        {id, info}
      end)

    {:reply, result, state}
  end

  def handle_call(:status, _from, state) do
    plugins = Map.values(state.plugins)
    configured = Enum.map(plugins, & &1.id())
    connected = Enum.filter(configured, &adapter_running_by_id?(state, &1))
    {:reply, %{configured: configured, connected: connected}, state}
  end

  def handle_call({:logout, channel_id}, _from, state) do
    case Map.get(state.plugins, channel_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      plugin ->
        _ = LemonChannels.Application.stop_adapter(plugin)
        plugins = Map.delete(state.plugins, channel_id)
        {:reply, :ok, %{state | plugins: plugins}}
    end
  end

  defp adapter_running_by_id?(state, channel_id) do
    case Map.get(state.plugins, channel_id) do
      nil -> false
      plugin -> adapter_running?(plugin)
    end
  end

  defp adapter_running?(plugin_module) when is_atom(plugin_module) do
    children =
      try do
        DynamicSupervisor.which_children(LemonChannels.AdapterSupervisor)
      rescue
        _ -> []
      end

    Enum.any?(children, fn
      {^plugin_module, pid, _type, _modules} when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end)
  end
end
