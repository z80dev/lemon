defmodule LemonCore.SubagentRegistry do
  @moduledoc """
  Registry of available `LemonCore.SubagentRunner` implementations.

  Runners live with the vendor they wrap — the CLI wrappers in
  `lemon_cli_runners`, the in-process agent in `coding_agent` — and register
  themselves when their application starts:

      LemonCore.SubagentRegistry.register(LemonCliRunners.CodexSubagent)

  The agent's `task` tool then asks this registry which engines exist, what to
  say about each in its tool description, and which module to run. Nothing in
  the agent names a vendor.

  This is `LemonGateway.EngineRegistry`'s idiom, one layer down: registration
  validates the id, is idempotent, replaces an id whose module changed, and is
  persisted to `:lemon_core, :subagent_runners` so a registry restart rebuilds
  the same set.

  A runner is third-party code called from inside this process, so `id/0`,
  `describe/0`, `default_policy/0` and `routable?/0` are all called defensively:
  a runner that raises is logged and skipped, not fatal to the registry.

  ## Relationship to `LemonCore.EngineCatalog`

  Registering a runner whose `c:LemonCore.SubagentRunner.routable?/0` is true
  publishes its id to `:lemon_core, :registered_engines`, which the catalog
  unions with its built-in defaults, so router-level engine validation reflects
  what is actually installed.

  It deliberately does *not* touch `:lemon_core, :known_engines`: that key is
  the operator's own list, and an operator who narrows it to disable an engine
  must not have it widened again by whichever package happens to be in the
  release. When it is set, the catalog ignores registrations entirely.
  """
  use GenServer

  alias LemonCore.SubagentRunner

  require Logger

  @type id :: String.t()

  @typedoc "What the registry knows about one runner."
  @type entry :: %{
          id: id(),
          module: module(),
          summary: String.t(),
          caveats: [String.t()],
          policy: atom(),
          routable?: boolean()
        }

  @reserved_ids ~w(default help)
  @id_regex ~r/^[a-z][a-z0-9_-]*$/

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Registers a runner module.

  Idempotent; re-registering an id with a different module replaces it.
  Returns `{:error, :unavailable}` for any registry exit — not running, mid
  restart, call timed out — so an application booting outside a lemon_core
  runtime does not crash, and `{:error, reason}` when the module does not
  satisfy the contract.
  """
  @spec register(module()) :: :ok | {:error, term()}
  def register(module) when is_atom(module) do
    GenServer.call(__MODULE__, {:register, module})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Removes the runner registered under `id`. Always `:ok`, even if there is none.

  With the registry down this still drops the module from the persisted list,
  because `entries/0` falls back to that list: answering `:ok` while every
  reader still sees the runner would be a lie.
  """
  @spec unregister(id()) :: :ok
  def unregister(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:unregister, id})
  catch
    :exit, _ -> forget(id)
  end

  @doc "All registered runners, in registration order."
  @spec entries() :: [entry()]
  def entries do
    safe_call(:entries, fn -> build_entries(configured_modules()) end)
  end

  @doc "Registered runner ids, in registration order."
  @spec list_ids() :: [id()]
  def list_ids, do: Enum.map(entries(), & &1.id)

  @doc "The entry registered under `id`, or `:error`."
  @spec fetch(term()) :: {:ok, entry()} | :error
  def fetch(id) when is_binary(id) do
    case Enum.find(entries(), &(&1.id == id)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  def fetch(_id), do: :error

  @doc "The module registered under `id`, or `nil`."
  @spec module(term()) :: module() | nil
  def module(id) do
    case fetch(id) do
      {:ok, entry} -> entry.module
      :error -> nil
    end
  end

  @doc """
  The tool policy profile registered for `id`, or `nil` when `id` is unknown.
  """
  @spec policy(term()) :: atom() | nil
  def policy(id) do
    case fetch(id) do
      {:ok, entry} -> entry.policy
      :error -> nil
    end
  end

  @impl true
  def init(_opts) do
    configured = configured_modules()
    entries = build_entries(configured)
    sync_engine_catalog(entries)

    {:ok, %{entries: entries, configured: configured}}
  end

  @impl true
  def handle_call({:register, module}, _from, state) do
    case build_entry(module) do
      {:ok, entry} ->
        entries = upsert(state.entries, entry)
        configured = Enum.map(entries, & &1.module)

        persist(configured)
        sync_engine_catalog(entries)

        {:reply, :ok, %{state | entries: entries, configured: configured}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unregister, id}, _from, state) do
    entries = Enum.reject(state.entries, &(&1.id == id))
    configured = Enum.map(entries, & &1.module)

    persist(configured)

    {:reply, :ok, %{state | entries: entries, configured: configured}}
  end

  def handle_call(:entries, _from, state), do: {:reply, state.entries, state}

  # A caller that reaches the registry before lemon_core has started — or after
  # a crash, in the window before the supervisor restarts it — gets the
  # configured set rather than an exit. The task tool asks on every tool-schema
  # build, and an unavailable registry should degrade to "no runners", never
  # take the agent turn down.
  defp safe_call(request, fallback) do
    GenServer.call(__MODULE__, request)
  catch
    :exit, _ -> fallback.()
  end

  defp configured_modules do
    :lemon_core
    |> Application.get_env(:subagent_runners, [])
    |> List.wrap()
    |> Enum.filter(&is_atom/1)
  end

  defp persist(modules), do: Application.put_env(:lemon_core, :subagent_runners, modules)

  # The write-side twin of `safe_call/2`: with no process to hold state, the
  # persisted list *is* the registry, so unregistering has to edit it directly.
  defp forget(id) do
    kept =
      Enum.reject(configured_modules(), fn module ->
        match?({:ok, ^id}, runner_id(module))
      end)

    persist(kept)

    :ok
  end

  defp build_entries(modules) do
    Enum.reduce(modules, [], fn module, acc ->
      case build_entry(module) do
        {:ok, entry} ->
          upsert(acc, entry)

        {:error, reason} ->
          Logger.warning("subagent runner #{inspect(module)} not registered: #{inspect(reason)}")

          acc
      end
    end)
  end

  defp build_entry(module) do
    with :ok <- ensure_loaded(module),
         {:ok, id} <- runner_id(module),
         {:ok, description} <- runner_description(module) do
      {:ok,
       %{
         id: id,
         module: module,
         summary: description.summary,
         caveats: description.caveats,
         policy: safe(module, :default_policy, [], SubagentRunner.default_policy()),
         routable?: safe(module, :routable?, [], true) == true
       }}
    end
  end

  defp ensure_loaded(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :id, 0) do
      :ok
    else
      {:error, :not_loaded}
    end
  end

  defp runner_id(module) do
    case safe(module, :id, [], nil) do
      id when is_binary(id) -> validate_id(id)
      other -> {:error, {:invalid_id, other}}
    end
  end

  defp runner_description(module) do
    module
    |> safe(:describe, [], nil)
    |> SubagentRunner.normalize_description()
  end

  defp validate_id(id) when id in @reserved_ids, do: {:error, {:reserved_id, id}}

  defp validate_id(id) do
    if Regex.match?(@id_regex, id), do: {:ok, id}, else: {:error, {:invalid_id, id}}
  end

  # Runners are third-party code running in this process; a raise here is the
  # runner's bug and must not become the registry's crash.
  defp safe(module, fun, args, default) do
    if function_exported?(module, fun, length(args)) do
      apply(module, fun, args)
    else
      default
    end
  rescue
    error ->
      Logger.error(
        "subagent runner #{inspect(module)} raised in #{fun}/#{length(args)}: " <>
          Exception.message(error)
      )

      default
  catch
    kind, reason ->
      Logger.error(
        "subagent runner #{inspect(module)} #{kind} in #{fun}/#{length(args)}: #{inspect(reason)}"
      )

      default
  end

  defp upsert(entries, entry) do
    case Enum.find_index(entries, &(&1.id == entry.id)) do
      nil -> entries ++ [entry]
      index -> List.replace_at(entries, index, entry)
    end
  end

  defp sync_engine_catalog(entries) do
    routable = entries |> Enum.filter(& &1.routable?) |> Enum.map(& &1.id)
    published = Application.get_env(:lemon_core, :registered_engines, [])
    merged = Enum.uniq(List.wrap(published) ++ routable)

    if merged != published do
      Application.put_env(:lemon_core, :registered_engines, merged)
    end

    :ok
  end
end
