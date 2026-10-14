defmodule LemonControlPlane.Methods.Registry do
  @moduledoc """
  Method registry with dispatch for the control plane.

  This GenServer maintains an ETS table mapping method names to handler modules.
  Handler modules must implement the `LemonControlPlane.Method` behaviour.

  ## Method Behaviour

  Handler modules must implement:

      @callback name() :: String.t()
      @callback scopes() :: [atom()]
      @callback handle(params :: map() | nil, ctx :: map()) ::
        {:ok, payload :: term()}
        | {:error, code :: atom(), message :: String.t(), details :: term() | nil}

  Handlers that wait for user input or other slow external work may also return
  `:async` from the optional `dispatch_mode/0` callback. The WebSocket then
  executes that handler outside the connection process so event and approval
  traffic remains live while the request is pending.
  """

  use GenServer

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Protocol.{Errors, Schemas}

  @table __MODULE__

  # Built-in method modules
  @builtin_methods [
    LemonControlPlane.Methods.Health,
    LemonControlPlane.Methods.Status,
    LemonControlPlane.Methods.DoctorRun,
    LemonControlPlane.Methods.Agent,
    LemonControlPlane.Methods.AgentWait,
    LemonControlPlane.Methods.AgentDirectoryList,
    # Goals
    LemonControlPlane.Methods.GoalSet,
    LemonControlPlane.Methods.GoalStatus,
    LemonControlPlane.Methods.GoalPause,
    LemonControlPlane.Methods.GoalResume,
    LemonControlPlane.Methods.GoalClear,
    # Logs
    LemonControlPlane.Methods.LogsTail,
    # Channels
    LemonControlPlane.Methods.CommandsCatalog,
    LemonControlPlane.Methods.BackgroundStart,
    LemonControlPlane.Methods.BackgroundList,
    LemonControlPlane.Methods.BackgroundStatus,
    LemonControlPlane.Methods.BackgroundResult,
    LemonControlPlane.Methods.BackgroundCancel,
    LemonControlPlane.Methods.SessionBtw,
    # Models
    LemonControlPlane.Methods.ModelsList,
    # User-managed profiles
    LemonControlPlane.Methods.ProfilesList,
    LemonControlPlane.Methods.ProfilesGet,
    LemonControlPlane.Methods.ProfilesCreate,
    LemonControlPlane.Methods.ProfilesClone,
    LemonControlPlane.Methods.ProfilesRename,
    LemonControlPlane.Methods.ProfilesExport,
    LemonControlPlane.Methods.ProfilesDelete,
    LemonControlPlane.Methods.ProfilesRoster,
    LemonControlPlane.Methods.ProfileChat,
    # Profile-scoped memory
    LemonControlPlane.Methods.MemoryList,
    LemonControlPlane.Methods.MemorySearch,
    LemonControlPlane.Methods.MemoryGet,
    LemonControlPlane.Methods.MemoryAdd,
    LemonControlPlane.Methods.MemoryDelete,
    LemonControlPlane.Methods.MemoryTransfer,
    LemonControlPlane.Methods.MemoryTransferStatus,
    # Agents
    LemonControlPlane.Methods.AgentsList,
    # Skills
    LemonControlPlane.Methods.SkillsHermesCatalog,
    LemonControlPlane.Methods.SkillsInstall,
    LemonControlPlane.Methods.SkillsList,
    LemonControlPlane.Methods.SkillsEnable,
    LemonControlPlane.Methods.SkillsDisable,
    # MCP server connections
    LemonControlPlane.Methods.McpServersList,
    LemonControlPlane.Methods.McpServersRefresh,
    # Portable skill bundles and automation blueprints
    LemonControlPlane.Methods.BlueprintsList,
    LemonControlPlane.Methods.BlueprintsInspect,
    LemonControlPlane.Methods.BlueprintsValidate,
    LemonControlPlane.Methods.BlueprintsPreview,
    LemonControlPlane.Methods.BlueprintsActivate,
    # Sessions
    LemonControlPlane.Methods.SessionsList,
    LemonControlPlane.Methods.SessionsGet,
    LemonControlPlane.Methods.SessionsHistory,
    LemonControlPlane.Methods.SessionsStats,
    LemonControlPlane.Methods.SessionsPreview,
    LemonControlPlane.Methods.SessionsDelete,
    LemonControlPlane.Methods.SessionsPatch,
    LemonControlPlane.Methods.SessionsMetadataPatch,
    LemonControlPlane.Methods.SessionsExport,
    LemonControlPlane.Methods.SessionsPrune,
    LemonControlPlane.Methods.SessionsReset,
    LemonControlPlane.Methods.SessionsCompact,
    LemonControlPlane.Methods.SessionsTree,
    LemonControlPlane.Methods.SessionsRewind,
    LemonControlPlane.Methods.SessionsCreate,
    LemonControlPlane.Methods.SessionsPlan,
    LemonControlPlane.Methods.SessionsContext,
    LemonControlPlane.Methods.SessionsChanges,
    LemonControlPlane.Methods.SessionsFork,
    LemonControlPlane.Methods.SessionsActive,
    LemonControlPlane.Methods.SessionsActiveList,
    LemonControlPlane.Methods.SessionDetail,
    # Runs
    LemonControlPlane.Methods.RunsActiveList,
    LemonControlPlane.Methods.RunsRecentList,
    # Tasks
    LemonControlPlane.Methods.TasksActiveList,
    LemonControlPlane.Methods.TasksRecentList,
    # Cron
    LemonControlPlane.Methods.CronList,
    LemonControlPlane.Methods.CronAdd,
    LemonControlPlane.Methods.CronUpdate,
    LemonControlPlane.Methods.CronPause,
    LemonControlPlane.Methods.CronResume,
    LemonControlPlane.Methods.CronAbort,
    LemonControlPlane.Methods.CronRemove,
    LemonControlPlane.Methods.CronRun,
    LemonControlPlane.Methods.CronRuns,
    LemonControlPlane.Methods.CronAudit,
    LemonControlPlane.Methods.CronStatus,
    # Exec approvals
    LemonControlPlane.Methods.ExecApprovalsGet,
    LemonControlPlane.Methods.ExecApprovalResolve,
    # Chat
    LemonControlPlane.Methods.ChatSend,
    LemonControlPlane.Methods.ChatAbort,
    LemonControlPlane.Methods.ChatHistory,
    # Execution node pairing and invocation
    LemonControlPlane.Methods.NodePairRequest,
    LemonControlPlane.Methods.NodePairApprove,
    LemonControlPlane.Methods.NodeInvoke,
    LemonControlPlane.Methods.NodeInvokeResult,
    LemonControlPlane.Methods.NodeInvokeControlResult,
    LemonControlPlane.Methods.NodesList,
    LemonControlPlane.Methods.NodesRevoke,
    # Config
    LemonControlPlane.Methods.ConfigGet,
    LemonControlPlane.Methods.ConfigSet,
    # Connect challenge (node pairing handshake)
    LemonControlPlane.Methods.ConnectChallenge,
    # omp delegate sessions
    LemonControlPlane.Methods.OmpStatus,
    LemonControlPlane.Methods.OmpSessionsList,
    LemonControlPlane.Methods.OmpSessionsGet,
    LemonControlPlane.Methods.OmpSessionsDiscover,
    LemonControlPlane.Methods.OmpSessionsStart,
    LemonControlPlane.Methods.OmpSessionsResume,
    LemonControlPlane.Methods.OmpSessionsSend,
    LemonControlPlane.Methods.OmpSessionsCancel,
    LemonControlPlane.Methods.OmpSessionsClose,
    # Usage
    LemonControlPlane.Methods.UsageStatus,
    LemonControlPlane.Methods.UsageCost
  ]

  ## Client API

  @doc """
  Starts the method registry.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Lists all registered method names.
  """
  @spec list_methods() :: [String.t()]
  def list_methods do
    :ets.tab2list(@table)
    |> Enum.map(fn {name, _module} -> name end)
    |> Enum.sort()
  end

  @doc "Returns whether a registered handler must run outside the WebSocket process."
  @spec dispatch_mode(String.t()) :: :inline | :async
  def dispatch_mode(method) do
    case lookup(method) do
      {:ok, module} ->
        if function_exported?(module, :dispatch_mode, 0) and module.dispatch_mode() == :async,
          do: :async,
          else: :inline

      {:error, :not_found} ->
        :inline
    end
  end

  @doc """
  Dispatches a method call to the appropriate handler.

  Returns `{:ok, payload}` or `{:error, term()}`.
  """
  @spec dispatch(String.t(), map() | nil, map()) :: {:ok, term()} | {:error, term()}
  def dispatch(method, params, ctx) do
    case lookup(method) do
      {:ok, module} ->
        # Validate params against schema
        case Schemas.validate(method, params) do
          :ok ->
            # Check authorization
            scopes = module.scopes()

            case Authorize.authorize(ctx.auth, method, scopes) do
              :ok ->
                try do
                  module.handle(params, ctx)
                rescue
                  e ->
                    {:error,
                     Errors.internal_error("Method execution failed", Exception.message(e))}
                end

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, Errors.invalid_request(reason)}
        end

      {:error, :not_found} ->
        {:error, Errors.method_not_found(method)}
    end
  end

  @doc """
  Looks up a method handler module by name.
  """
  @spec lookup(String.t()) :: {:ok, module()} | {:error, :not_found}
  def lookup(method) do
    case :ets.lookup(@table, method) do
      [{^method, module}] -> {:ok, module}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Registers a method handler module.
  """
  @spec register(module()) :: :ok
  def register(module) do
    GenServer.call(__MODULE__, {:register, module})
  end

  @doc """
  Unregisters a method by name.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(method) do
    GenServer.call(__MODULE__, {:unregister, method})
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    for module <- @builtin_methods do
      :ets.insert(table, {module.name(), module})
    end

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, module}, _from, state) do
    name = module.name()
    :ets.insert(state.table, {name, module})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unregister, method}, _from, state) do
    :ets.delete(state.table, method)
    {:reply, :ok, state}
  end
end

defmodule LemonControlPlane.Method do
  @moduledoc """
  Behaviour for control plane method handlers.
  """

  @doc """
  Returns the method name (e.g., "health", "agent", "sessions.list").
  """
  @callback name() :: String.t()

  @doc """
  Returns the required scopes for this method.

  Return an empty list for public methods.
  """
  @callback scopes() :: [atom()]

  @doc """
  Selects how the WebSocket runs the handler.

  Use `:async` only for handlers that can block on user approval or slow
  external work and do not require `self()` to remain the connection process.
  All other handlers default to `:inline`.
  """
  @callback dispatch_mode() :: :inline | :async
  @optional_callbacks dispatch_mode: 0

  @doc """
  Handles the method call.

  ## Parameters

  - `params` - The method parameters from the request (may be nil)
  - `ctx` - The connection context including:
    - `auth` - Authentication context
    - `conn_id` - Connection ID
    - `conn_pid` - Connection process PID

  ## Return Values

  - `{:ok, payload}` - Success with response payload
  - `{:error, {code, message}}` - Error with code and message
  - `{:error, {code, message, details}}` - Error with additional details
  """
  @callback handle(params :: map() | nil, ctx :: map()) ::
              {:ok, term()}
              | {:error, {atom(), String.t()}}
              | {:error, {atom(), String.t(), term()}}

  @doc """
  Extracts a required parameter from the params map.

  Returns `{:ok, value}` if present, or an `{:error, ...}` tuple suitable for
  returning directly from `handle/2`.
  """
  @spec require_param(map(), String.t()) :: {:ok, term()} | {:error, {atom(), String.t(), nil}}
  def require_param(params, key) do
    case params[key] do
      nil -> {:error, {:invalid_request, "#{key} is required", nil}}
      value -> {:ok, value}
    end
  end
end
