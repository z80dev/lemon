defmodule LemonChannels.Registry do
  @moduledoc """
  Registry for channel plugins.

  Manages registration and lookup of channel plugins.
  """

  use GenServer

  require Logger

  @call_timeout_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a channel plugin.
  """
  @spec register(module()) :: :ok | {:error, term()}
  def register(plugin_module) do
    GenServer.call(__MODULE__, {:register, plugin_module}, @call_timeout_ms)
  end

  @doc """
  Unregister a channel plugin.
  """
  @spec unregister(binary()) :: :ok
  def unregister(plugin_id) do
    GenServer.call(__MODULE__, {:unregister, plugin_id}, @call_timeout_ms)
  end

  @doc """
  Get a plugin by ID.
  """
  @spec get_plugin(binary()) :: module() | nil
  def get_plugin(plugin_id) do
    GenServer.call(__MODULE__, {:get, plugin_id}, @call_timeout_ms)
  catch
    :exit, reason ->
      Logger.warning("[Channels.Registry] get_plugin(#{inspect(plugin_id)}) failed: #{inspect(reason)}")
      nil
  end

  @doc """
  List all registered plugins.
  """
  @spec list_plugins() :: [module()]
  def list_plugins do
    GenServer.call(__MODULE__, :list, @call_timeout_ms)
  end

  @doc """
  List adapters with metadata for status UIs.

  Returns a list of `{channel_id, info}` tuples.
  """
  @spec list() :: [{binary(), map()}]
  def list do
    GenServer.call(__MODULE__, :list_info, @call_timeout_ms)
  end

  @doc """
  Summarize configured/connected channel adapters.
  """
  @spec status() :: %{configured: [binary()], connected: [binary()]}
  def status do
    GenServer.call(__MODULE__, :status, @call_timeout_ms)
  end

  @doc """
  Stop and unregister a channel adapter by `channel_id`.
  """
  @spec logout(binary()) :: :ok | {:error, :not_found} | {:error, term()}
  def logout(channel_id) when is_binary(channel_id) do
    GenServer.call(__MODULE__, {:logout, channel_id}, @call_timeout_ms)
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
    expected_child_module = plugin_child_module(plugin_module)

    children =
      try do
        DynamicSupervisor.which_children(LemonChannels.AdapterSupervisor)
      rescue
        _ -> []
      end

    Enum.any?(children, fn
      {_id, pid, _type, modules} when is_pid(pid) ->
        Process.alive?(pid) and
          child_matches_plugin?(modules, plugin_module, expected_child_module)

      _ ->
        false
    end) or
      named_process_running?(expected_child_module)
  end

  defp plugin_child_module(plugin_module) when is_atom(plugin_module) do
    case plugin_module.child_spec([]) do
      %{start: {module, _func, _args}} when is_atom(module) -> module
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp child_matches_plugin?(modules, plugin_module, expected_child_module)
       when is_list(modules) do
    Enum.member?(modules, plugin_module) or
      (is_atom(expected_child_module) and Enum.member?(modules, expected_child_module))
  end

  defp child_matches_plugin?(_, _plugin_module, _expected_child_module), do: false

  defp named_process_running?(module) when is_atom(module) do
    case Process.whereis(module) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp named_process_running?(_), do: false
end
