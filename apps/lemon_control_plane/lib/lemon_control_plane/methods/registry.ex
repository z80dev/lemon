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
  """

  use GenServer

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Protocol.{Errors, Schemas}

  @table __MODULE__

  # Built-in method modules
  @builtin_methods [
    LemonControlPlane.Methods.Health,
    LemonControlPlane.Methods.Status,
    LemonControlPlane.Methods.IntrospectionSnapshot,
    LemonControlPlane.Methods.Agent,
    LemonControlPlane.Methods.AgentWait,
    LemonControlPlane.Methods.AgentIdentityGet,
    LemonControlPlane.Methods.AgentInboxSend,
    LemonControlPlane.Methods.AgentDirectoryList,
    LemonControlPlane.Methods.AgentTargetsList,
    LemonControlPlane.Methods.AgentEndpointsList,
    LemonControlPlane.Methods.AgentEndpointsSet,
    LemonControlPlane.Methods.AgentEndpointsDelete,
    # Logs
    LemonControlPlane.Methods.LogsTail,
    # Channels
    LemonControlPlane.Methods.ChannelsStatus,
    LemonControlPlane.Methods.TransportsStatus,
    LemonControlPlane.Methods.ChannelsLogout,
    # Models
    LemonControlPlane.Methods.ModelsList,
    # Agents
    LemonControlPlane.Methods.AgentsList,
    LemonControlPlane.Methods.AgentsFilesList,
    LemonControlPlane.Methods.AgentsFilesGet,
    LemonControlPlane.Methods.AgentsFilesSet,
    # Skills
    LemonControlPlane.Methods.SkillsStatus,
    LemonControlPlane.Methods.SkillsBins,
    LemonControlPlane.Methods.SkillsInstall,
    LemonControlPlane.Methods.SkillsUpdate,
    # Sessions
    LemonControlPlane.Methods.SessionsList,
    LemonControlPlane.Methods.SessionsPreview,
    LemonControlPlane.Methods.SessionsDelete,
    LemonControlPlane.Methods.SessionsPatch,
    LemonControlPlane.Methods.SessionsReset,
    LemonControlPlane.Methods.SessionsCompact,
    LemonControlPlane.Methods.SessionsActive,
    LemonControlPlane.Methods.SessionsActiveList,
    # Cron
    LemonControlPlane.Methods.CronList,
    LemonControlPlane.Methods.CronAdd,
    LemonControlPlane.Methods.CronUpdate,
    LemonControlPlane.Methods.CronRemove,
    LemonControlPlane.Methods.CronRun,
    LemonControlPlane.Methods.CronRuns,
    LemonControlPlane.Methods.CronStatus,
    # Exec approvals
    LemonControlPlane.Methods.ExecApprovalsGet,
    LemonControlPlane.Methods.ExecApprovalsSet,
    LemonControlPlane.Methods.ExecApprovalsNodeGet,
    LemonControlPlane.Methods.ExecApprovalsNodeSet,
    LemonControlPlane.Methods.ExecApprovalResolve,
    LemonControlPlane.Methods.ExecApprovalRequest,
    # Chat
    LemonControlPlane.Methods.ChatSend,
    LemonControlPlane.Methods.ChatAbort,
    LemonControlPlane.Methods.ChatHistory,
    # Send
    LemonControlPlane.Methods.Send,
    # Wake/Heartbeats
    LemonControlPlane.Methods.Wake,
    LemonControlPlane.Methods.SetHeartbeats,
    LemonControlPlane.Methods.LastHeartbeat,
    # Talk mode
    LemonControlPlane.Methods.TalkMode,
    # Browser
    LemonControlPlane.Methods.BrowserRequest,
    # Node pairing
    LemonControlPlane.Methods.NodePairRequest,
    LemonControlPlane.Methods.NodePairList,
    LemonControlPlane.Methods.NodePairApprove,
    LemonControlPlane.Methods.NodePairReject,
    LemonControlPlane.Methods.NodePairVerify,
    # Node management
    LemonControlPlane.Methods.NodeRename,
    LemonControlPlane.Methods.NodeList,
    LemonControlPlane.Methods.NodeDescribe,
    LemonControlPlane.Methods.NodeInvoke,
    LemonControlPlane.Methods.NodeInvokeResult,
    LemonControlPlane.Methods.NodeEvent,
    # System methods
    LemonControlPlane.Methods.SystemPresence,
    LemonControlPlane.Methods.SystemEvent,
    # Voicewake
    LemonControlPlane.Methods.VoicewakeGet,
    LemonControlPlane.Methods.VoicewakeSet,
    # TTS
    LemonControlPlane.Methods.TtsStatus,
    LemonControlPlane.Methods.TtsProviders,
    LemonControlPlane.Methods.TtsEnable,
    LemonControlPlane.Methods.TtsDisable,
    LemonControlPlane.Methods.TtsConvert,
    LemonControlPlane.Methods.TtsSetProvider,
    # Update
    LemonControlPlane.Methods.UpdateRun,
    # Config
    LemonControlPlane.Methods.ConfigGet,
    LemonControlPlane.Methods.ConfigSet,
    LemonControlPlane.Methods.ConfigPatch,
    LemonControlPlane.Methods.ConfigSchema,
    LemonControlPlane.Methods.ConfigReload,
    # Secrets
    LemonControlPlane.Methods.SecretsStatus,
    LemonControlPlane.Methods.SecretsList,
    LemonControlPlane.Methods.SecretsSet,
    LemonControlPlane.Methods.SecretsDelete,
    LemonControlPlane.Methods.SecretsExists,
    # Device pairing
    LemonControlPlane.Methods.DevicePairRequest,
    LemonControlPlane.Methods.DevicePairApprove,
    LemonControlPlane.Methods.DevicePairReject,
    # Wizard
    LemonControlPlane.Methods.WizardStart,
    LemonControlPlane.Methods.WizardStep,
    LemonControlPlane.Methods.WizardCancel,
    # Connect
    LemonControlPlane.Methods.ConnectChallenge,
    # Usage
    LemonControlPlane.Methods.UsageStatus,
    LemonControlPlane.Methods.UsageCost
  ]

  @capability_methods %{
    voicewake: [
      LemonControlPlane.Methods.VoicewakeGet,
      LemonControlPlane.Methods.VoicewakeSet
    ],
    tts: [
      LemonControlPlane.Methods.TtsStatus,
      LemonControlPlane.Methods.TtsProviders,
      LemonControlPlane.Methods.TtsEnable,
      LemonControlPlane.Methods.TtsDisable,
      LemonControlPlane.Methods.TtsConvert,
      LemonControlPlane.Methods.TtsSetProvider
    ],
    updates: [
      LemonControlPlane.Methods.UpdateRun
    ],
    device_pairing: [
      LemonControlPlane.Methods.DevicePairRequest,
      LemonControlPlane.Methods.DevicePairApprove,
      LemonControlPlane.Methods.DevicePairReject,
      LemonControlPlane.Methods.ConnectChallenge
    ],
    wizard: [
      LemonControlPlane.Methods.WizardStart,
      LemonControlPlane.Methods.WizardStep,
      LemonControlPlane.Methods.WizardCancel
    ]
  }

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

    # Register built-in methods
    for module <- enabled_builtin_methods() do
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

  defp enabled_builtin_methods do
    disabled_modules =
      enabled_capabilities()
      |> disabled_capabilities()
      |> Enum.flat_map(fn capability -> Map.get(@capability_methods, capability, []) end)
      |> MapSet.new()

    @builtin_methods
    |> Enum.reject(&MapSet.member?(disabled_modules, &1))
    |> Enum.uniq()
  end

  defp enabled_capabilities do
    defaults = @capability_methods |> Map.keys() |> MapSet.new()

    case Application.get_env(:lemon_control_plane, :capabilities, :default) do
      :default ->
        defaults

      list when is_list(list) ->
        list
        |> Enum.filter(&is_atom/1)
        |> MapSet.new()

      map when is_map(map) ->
        known = Map.keys(@capability_methods)

        map
        |> Enum.reduce(MapSet.new(), fn
          {capability, true}, acc when is_atom(capability) ->
            MapSet.put(acc, capability)

          {capability, value}, acc when is_binary(capability) and value in [true, "true", 1] ->
            case Enum.find(known, &(Atom.to_string(&1) == capability)) do
              nil -> acc
              cap -> MapSet.put(acc, cap)
            end

          _, acc ->
            acc
        end)

      _ ->
        defaults
    end
  end

  defp disabled_capabilities(enabled) do
    @capability_methods
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(enabled, &1))
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
