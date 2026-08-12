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

  What gets written back is the *union* of the configured list and the runtime
  registrations, not the set this process is currently serving. Those differ: a
  configured engine whose module is not loadable yet is skipped for lookups but
  stays in the configuration, because "not loadable at boot" is a statement
  about start order, not about intent. Persisting the serving set instead would
  let one unrelated `register/1` delete an engine the operator configured.

  An engine is third-party code called from inside this process, so every call
  into one — `c:LemonGateway.Engine.id/0` and
  `c:LemonGateway.Engine.extract_resume/1` — is isolated. An engine that raises
  is logged and skipped rather than taking the registry (and, through the
  supervisor's restart intensity, the gateway) down with it.
  """
  use GenServer

  require Logger

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
    configured =
      Application.get_env(:lemon_gateway, :engines, [
        LemonGateway.Engines.Echo,
        LemonGateway.Engines.Codex,
        LemonGateway.Engines.Claude,
        LemonGateway.Engines.Opencode,
        LemonGateway.Engines.Pi,
        LemonGateway.Engines.Kimi
      ])

    # A configured engine may live in an application that is not part of this
    # runtime, or in one that starts later; serve what is loadable now and keep
    # the rest in :configured so persist_engines/1 never drops it.
    engines = Enum.filter(configured, &loadable?/1)

    {map, order} =
      Enum.reduce(engines, {%{}, []}, fn mod, {map, order} = acc ->
        case valid_id(mod) do
          nil -> acc
          id -> {Map.put(map, id, mod), order ++ [mod]}
        end
      end)

    {:ok, %{map: map, order: order, configured: configured}}
  end

  @impl true
  def handle_call({:register, module}, _from, state) do
    id = module.id()
    validate_id!(id)

    order = upsert(state.order, module, id)
    configured = upsert(state.configured, module, id)

    persist_engines(configured)

    {:reply, :ok,
     %{state | map: Map.put(state.map, id, module), order: order, configured: configured}}
  rescue
    error -> {:reply, {:error, error}, state}
  end

  def handle_call(:list, _from, state) do
    {:reply, Enum.flat_map(state.order, fn mod -> List.wrap(safe_id(mod)) end), state}
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
        case safe_extract_resume(mod, text) do
          %LemonCore.ResumeToken{} = token -> {:ok, token}
          _ -> nil
        end
      end)

    {:reply, result, state}
  end

  defp loadable?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :id, 0)
  end

  # Replace the entry holding `id`, or append. Entries that cannot report an id
  # (an engine from an application that has not started yet) are left alone
  # rather than being treated as collisions.
  defp upsert(list, module, id) do
    cond do
      module in list ->
        list

      index = Enum.find_index(list, fn mod -> loadable?(mod) and safe_id(mod) == id end) ->
        List.replace_at(list, index, module)

      true ->
        list ++ [module]
    end
  end

  # An engine that *raises* is skipped; an engine that *answers* an unusable id
  # is still fatal at boot. The two are different failures: the first is a
  # broken plugin the gateway should survive, the second is a configuration
  # error the operator needs to see immediately, before any traffic arrives.
  defp valid_id(module) do
    case safe_id(module) do
      nil ->
        nil

      id ->
        validate_id!(id)
        id
    end
  end

  # Engines are third-party code running in this process; a raise here is the
  # engine's bug and must not become the registry's crash.
  defp safe_id(module) do
    module.id()
  rescue
    error ->
      Logger.error(
        "engine #{inspect(module)} raised in id/0, skipping it: #{Exception.message(error)}"
      )

      nil
  catch
    kind, reason ->
      Logger.error("engine #{inspect(module)} #{kind} in id/0, skipping it: #{inspect(reason)}")

      nil
  end

  defp safe_extract_resume(module, text) do
    module.extract_resume(text)
  rescue
    error ->
      Logger.error(
        "engine #{inspect(module)} raised in extract_resume/1, skipping it: " <>
          Exception.message(error)
      )

      nil
  catch
    kind, reason ->
      Logger.error(
        "engine #{inspect(module)} #{kind} in extract_resume/1, skipping it: #{inspect(reason)}"
      )

      nil
  end

  # Persist the union of configured and runtime-registered engines so a registry
  # restart rebuilds the same set. Deliberately not `state.order`: that is only
  # what is loadable right now, and writing it back would delete a configured
  # engine whose application had not started yet.
  defp persist_engines(configured) do
    Application.put_env(:lemon_gateway, :engines, configured)
  end

  defp validate_id!(id) when not is_binary(id) do
    raise ArgumentError, "engine id must be a string, got: #{inspect(id)}"
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
