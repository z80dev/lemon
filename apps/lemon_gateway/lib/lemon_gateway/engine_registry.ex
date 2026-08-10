defmodule LemonGateway.EngineRegistry do
  @moduledoc """
  Registry of available AI engine modules.

  Maintains a mapping of engine ID strings to their implementing modules.
  Validates engine IDs on registration and provides lookup and resume
  token extraction across all registered engines.

  The built-in engines are the CLI wrappers this app ships. Engines that live
  in another application register themselves at boot with `register/1` — that
  is how coding_agent contributes the `"lemon"` engine without the gateway
  depending on it. Registration also updates `:lemon_gateway, :engines`, so a
  registry restart keeps the engine.
  """
  use GenServer

  @type engine_id :: String.t()
  @type engine_mod :: module()

  @reserved_ids ~w(default help)
  @id_regex ~r/^[a-z][a-z0-9_-]*$/

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Returns a list of all registered engine IDs."
  @spec list_engines() :: [engine_id()]
  def list_engines, do: GenServer.call(__MODULE__, :list)

  @doc "Returns the engine module for the given ID, or raises if not found."
  @spec get_engine!(engine_id()) :: engine_mod()
  def get_engine!(id) do
    case get_engine(id) do
      nil -> raise ArgumentError, "unknown engine id: #{inspect(id)}"
      mod -> mod
    end
  end

  @doc "Returns the engine module for the given ID, or `nil` if not registered."
  @spec get_engine(engine_id()) :: engine_mod() | nil
  def get_engine(id), do: GenServer.call(__MODULE__, {:get_or_nil, id})

  @doc """
  Registers an engine module at runtime.

  Idempotent: registering the same module again is a no-op, and re-registering
  an id with a different module replaces it. Returns `{:error, :unavailable}`
  when the registry is not running, so a caller booting outside the gateway
  runtime does not crash.
  """
  @spec register(engine_mod()) :: :ok | {:error, term()}
  def register(module) when is_atom(module) do
    GenServer.call(__MODULE__, {:register, module})
  catch
    :exit, {:noproc, _} -> {:error, :unavailable}
    :exit, {:normal, _} -> {:error, :unavailable}
  end

  @doc """
  Iterates all registered engines and calls extract_resume/1 on each until one returns
  a non-nil ResumeToken. Returns `{:ok, token}` if found, `:none` otherwise.
  """
  @spec extract_resume(String.t()) :: {:ok, LemonCore.ResumeToken.t()} | :none
  def extract_resume(text) do
    GenServer.call(__MODULE__, {:extract_resume, text})
  end

  @impl true
  def init(_opts) do
    engines =
      Application.get_env(:lemon_gateway, :engines, [
        LemonGateway.Engines.Echo,
        LemonGateway.Engines.Codex,
        LemonGateway.Engines.Claude,
        LemonGateway.Engines.Droid,
        LemonGateway.Engines.Opencode,
        LemonGateway.Engines.Pi,
        LemonGateway.Engines.Kimi
      ])

    # A configured engine may live in an application that is not part of this
    # runtime; skip it rather than taking the registry down.
    engines = Enum.filter(engines, &loadable?/1)

    map =
      engines
      |> Enum.reduce(%{}, fn mod, acc ->
        id = mod.id()
        validate_id!(id)
        Map.put(acc, id, mod)
      end)

    {:ok, %{map: map, order: engines}}
  end

  @impl true
  def handle_call({:register, module}, _from, state) do
    id = module.id()
    validate_id!(id)

    order =
      case Enum.find_index(state.order, &(&1.id() == id)) do
        nil -> state.order ++ [module]
        index -> List.replace_at(state.order, index, module)
      end

    persist_engines(order)

    {:reply, :ok, %{state | map: Map.put(state.map, id, module), order: order}}
  rescue
    error -> {:reply, {:error, error}, state}
  end

  def handle_call(:list, _from, state) do
    {:reply, Enum.map(state.order, & &1.id()), state}
  end

  def handle_call({:get, id}, _from, state) do
    {:reply, Map.get(state.map, id), state}
  end

  def handle_call({:get_or_nil, id}, _from, state) do
    {:reply, Map.get(state.map, id), state}
  end

  def handle_call({:extract_resume, text}, _from, state) do
    result =
      state.order
      |> Enum.find_value(:none, fn mod ->
        case mod.extract_resume(text) do
          %LemonCore.ResumeToken{} = token -> {:ok, token}
          _ -> nil
        end
      end)

    {:reply, result, state}
  end

  defp loadable?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :id, 0)
  end

  # Keep the configured list in step so a registry restart rebuilds the same
  # set of engines.
  defp persist_engines(order) do
    Application.put_env(:lemon_gateway, :engines, order)
  end

  defp validate_id!(id) when id in @reserved_ids do
    raise ArgumentError, "engine id reserved: #{id}"
  end

  defp validate_id!(id) do
    if Regex.match?(@id_regex, id) do
      :ok
    else
      raise ArgumentError, "invalid engine id: #{inspect(id)}"
    end
  end
end
