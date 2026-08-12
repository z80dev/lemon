defmodule LemonGateway.EngineRegistry do
  @moduledoc """
  Registry of available AI engine modules.

  Maintains a mapping of engine ID strings to their implementing modules.
  Validates engine IDs on registration and provides lookup and resume
  token extraction across all registered engines.

  The only engine this app ships is `LemonGateway.Engines.Echo`. Engines that
  live in another application register themselves at boot — that is how
  coding_agent contributes the `"lemon"` engine and lemon_cli_runners the
  vendor CLI engines, without the gateway depending on either.

  Two inputs, and they are not peers (mirrors `LemonCore.EngineCatalog`):

    * `config :lemon_gateway, :engines` is the *operator's* list. This process
      never writes it. When it is set, it is a ceiling: `register_default/1`
      (boot auto-registration by installed packages) becomes a no-op, so
      narrowing the list is how an operator disables an engine the build
      happens to ship.
    * `:lemon_gateway, :registered_engines` is what `register/1` persists, so a
      registry restart keeps runtime registrations. It extends the configured
      (or default) list; entries with a colliding id replace the stale module.

  A configured engine whose module is not loadable yet is skipped for lookups
  but stays in the configuration, because "not loadable at boot" is a statement
  about start order, not about intent.

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
  Registers an engine at boot, unless the operator configured the engine list.

  This is the call for packages announcing the engines they ship from their
  application callback. When `config :lemon_gateway, :engines` is
  explicitly set, that list is a ceiling — an operator who narrowed it to
  disable a vendor engine must not have it re-enabled by whichever package
  happens to be in the release — so the registration is skipped with `:ok`.
  Without operator configuration this behaves exactly like `register/1`.
  """
  @spec register_default(engine_mod()) :: :ok | {:error, term()}
  def register_default(module) when is_atom(module) do
    GenServer.call(__MODULE__, {:register_default, module})
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
    operator_configured? =
      match?(
        {:ok, engines} when is_list(engines),
        Application.fetch_env(:lemon_gateway, :engines)
      )

    configured = Application.get_env(:lemon_gateway, :engines, [LemonGateway.Engines.Echo])
    registered = Application.get_env(:lemon_gateway, :registered_engines, [])

    # A configured engine may live in an application that is not part of this
    # runtime, or in one that starts later; serve what is loadable now and keep
    # the rest in :configured, which this process never writes back anywhere.
    # Runtime registrations persisted to :registered_engines are folded on top
    # so a registry restart rebuilds the same serving set.
    engines =
      registered
      |> Enum.reduce(configured, &merge_registered(&2, &1))
      |> Enum.filter(&loadable?/1)

    {map, order} =
      Enum.reduce(engines, {%{}, []}, fn mod, {map, order} = acc ->
        case valid_id(mod) do
          nil -> acc
          id -> {Map.put(map, id, mod), order ++ [mod]}
        end
      end)

    {:ok,
     %{
       map: map,
       order: order,
       configured: configured,
       registered: registered,
       operator_configured?: operator_configured?
     }}
  end

  @impl true
  def handle_call({:register, module}, _from, state) do
    do_register(module, state)
  end

  def handle_call({:register_default, module}, _from, state) do
    if state.operator_configured? do
      Logger.debug(
        "engine #{inspect(module)} not auto-registered: operator configured :lemon_gateway, :engines"
      )

      {:reply, :ok, state}
    else
      do_register(module, state)
    end
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

  defp do_register(module, state) do
    id = module.id()
    validate_id!(id)

    order = upsert(state.order, module, id)
    registered = upsert(state.registered, module, id)

    persist_registered(registered)

    {:reply, :ok,
     %{state | map: Map.put(state.map, id, module), order: order, registered: registered}}
  rescue
    error -> {:reply, {:error, error}, state}
  end

  # Fold one persisted runtime registration into the configured list: replace
  # the configured entry serving the same id, or append. A registration that is
  # not loadable in this runtime is kept in :registered_engines but cannot
  # answer id/0, so it is left out of the serving fold.
  defp merge_registered(list, module) do
    with true <- loadable?(module),
         id when is_binary(id) <- safe_id(module) do
      upsert(list, module, id)
    else
      _ -> list
    end
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

  # Persist runtime registrations so a registry restart rebuilds the same set.
  # Deliberately a separate key from :engines: that one belongs to the
  # operator, and writing the serving set into it would both delete configured
  # engines whose applications had not started yet and make the operator's
  # narrowing indistinguishable from our own bookkeeping.
  defp persist_registered(registered) do
    Application.put_env(:lemon_gateway, :registered_engines, registered)
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
