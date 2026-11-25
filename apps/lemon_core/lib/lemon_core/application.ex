defmodule LemonCore.Application do
  @moduledoc """
  Application supervisor for the LemonCore OTP application.

  This module is the entry point for the lemon_core application. It starts
  the supervision tree with the following children:

  - The `LemonCore.Bus` backend - Phoenix.PubSub, or a Registry when
    `phoenix_pubsub` is not available
  - `LemonCore.ACPClientBridge` - Registry for direct ACP client request/reply
  - `LemonCore.NodeRegistry` - Socket-owned Registry and temporary invocation supervisors
  - `LemonCore.RuntimeCache` - Supervised runtime metadata and hook registrations
  - `LemonCore.Dedupe.Supervisor` - Supervises each named deduplication table owner
  - LemonCore.ConfigCache - Configuration caching service
  - LemonCore.Store - Key-value storage backend
  - `LemonCore.SessionActivity` - Presence of execution started outside router
    admission, checked against session lifecycle fences and rebuilt from
    surviving owners when it restarts
  - `LemonCore.Secrets.Usage` - Batched asynchronous secret usage metadata
  - `LemonCore.UsageLedger` - Serialized per-run usage/cost aggregation (finalize-run hook)
  - `LemonCore.RuntimeOwner` - Holds the cross-VM ownership lock of a
    file-backed store; only its holder reconciles other runtimes' records
  - `LemonCore.ExecApprovalExpiry` - Expires pending exec approvals whose run or
    session ended (finalize-run hook)
  - `LemonCore.Secrets.SourceTaskSupervisor` - Bounded external-source tasks
  - `LemonCore.Secrets.SourceCache` - Bounded optional process-local source cache
  - LemonCore.RunHistoryStore - Per-session run history (separate SQLite DB)
  - LemonCore.ConfigReloader - Runtime config reload orchestrator
  - LemonCore.ConfigReloader.Watcher - File-system watcher for config changes
  - `LemonCore.Drain` - Coordinated drain of registered participants before a
    graceful stop (installs the SIGTERM trap when configured)

  The supervisor uses a :one_for_one strategy, meaning if a child process
  crashes, only that process will be restarted.

  ## Boot modes

  `config :lemon_core, :boot_mode` selects the tree; `children/2` lists it.

  - `:runtime` (default) - the daemon, node workers and tests: everything above.
  - `:client` - one-shot CLI commands (`LemonCore.CLI.start/2`): no
    `RuntimeOwner`, approval recovery (`ExecApprovalExpiry` runs with
    `recover: false` and refuses resolution), Store sweeps, `RunHistoryStore`,
    `ConfigReloader`, `Watcher` or `Drain` (so no SIGTERM trap; `Drain.phase/0`
    reads `:serving`). A client VM therefore never expires, sweeps or reloads
    state owned by a running daemon.
  - `:read_only_client` - `:client` whose Store also refuses every mutation
    (`{:error, :read_only}`), for one-shot commands that only read.

  ## Service groups

  `config :lemon_core, :services` selects which groups of the tree start (see
  `service_groups/0`); every group starts when it is unset, which is what the
  packaged Lemon runtime uses.

  - `:core` (always) - `RuntimeCache`, `RuntimeLatch`, dedupe, the Bus,
    `ConfigCache`, `Store` and the secrets helpers: what the published
    packages (`lemon_ai`, `lemon_agent`, `lemon_memory`) need.
  - `:runtime_control` - the assistant runtime's control services: `Drain`,
    `ACPClientBridge`, `NodeRegistry`, `RuntimeOwner`, `SessionActivity`,
    `UsageLedger`, `ExecApprovalExpiry` and the config reloader.
  - `:run_history` - `RunHistoryStore` (needs the optional `:exqlite`).

  A library consumer that only uses the agent and store APIs selects
  `config :lemon_core, :services, [:core]` and starts none of the runtime's
  control processes. Durable memory lives in the `lemon_memory` app and
  supervises itself.

  A product declares the capabilities it cannot run without in
  `config :lemon_core, :required_capabilities`; in the `:runtime` boot mode
  this application refuses to start when one is unavailable (see
  `LemonCore.Capabilities`).

  ## Configuration

  The application reads configuration from the application environment:

  - `:lemon_core, :services` - The service groups to start (see above)
  - `:lemon_core, :required_capabilities` - Capabilities checked at boot
  - `:lemon_core, LemonCore.ConfigCache` - Options passed to ConfigCache
  - `:lemon_core, :logging` - File logging configuration (optional)
  - `:lemon_core, :logger` - `:logger` handlers to attach at boot (e.g. the
    Sentry error-reporting handler; see `docs/error-reporting.md`). Empty
    unless `SENTRY_DSN` is set at runtime, in which case this is a no-op.

  ## Examples

      # Starting the application
      Application.ensure_all_started(:lemon_core)

      # Accessing the supervisor
      Process.whereis(LemonCore.Supervisor)
  """

  use Application

  require Logger

  @typedoc "A group of lemon_core services; see the moduledoc."
  @type service_group :: :core | :runtime_control | :run_history

  @service_groups [:core, :runtime_control, :run_history]

  @impl true
  def start(_type, _args) do
    # Strip conversation content from OTP crash reports before any handler
    # (console, file, Sentry) formats them. See docs/error-reporting.md.
    :ok = LemonCore.CrashLogRedaction.install()

    # Attach any :logger handlers configured under :lemon_core, :logger (see
    # config/runtime.exs). A no-op when nothing is configured there.
    drop_unloadable_handlers()
    _ = Logger.add_handlers(:lemon_core)

    # If configured, install a log-to-file handler early so dropped/errored
    # messages can be diagnosed even when stdout/stderr isn't persisted.
    _ = LemonCore.Logging.maybe_add_file_handler()

    _ = LemonCore.ExecApprovalExpiry.init_runtime_id()
    # Captures this OS process's identity once for every lock acquisition and
    # logs an error when `ps` (needed to verify other holders) is missing.
    _ = LemonCore.Service.Identity.boot_check()
    mode = boot_mode()
    groups = service_groups()

    opts = [strategy: :one_for_one, name: LemonCore.Supervisor]

    with :ok <- check_capabilities(mode, groups),
         {:ok, pid} <- Supervisor.start_link(children(mode, groups), opts) do
      if mode == :runtime and :runtime_control in groups,
        do: :ok = LemonCore.Drain.maybe_install_signal_trap()

      {:ok, pid}
    end
  end

  @doc "The configured boot mode: `:runtime` unless a one-shot client chose otherwise."
  @spec boot_mode() :: :runtime | :client | :read_only_client
  def boot_mode do
    case Application.get_env(:lemon_core, :boot_mode, :runtime) do
      mode when mode in [:client, :read_only_client] -> mode
      _ -> :runtime
    end
  end

  @doc """
  The service groups this node starts, in a fixed order: `:core` plus the
  groups listed in `config :lemon_core, :services`, or every group when that
  is unset.

  Raises `ArgumentError` for a value that is not a list of known groups.
  """
  @spec service_groups() :: [service_group()]
  def service_groups do
    case Application.fetch_env(:lemon_core, :services) do
      :error ->
        @service_groups

      {:ok, groups} when is_list(groups) ->
        case groups -- @service_groups do
          [] ->
            Enum.filter(@service_groups, &(&1 == :core or &1 in groups))

          unknown ->
            raise ArgumentError,
                  "config :lemon_core, :services names unknown service groups " <>
                    "#{inspect(unknown)}; known: #{inspect(@service_groups)}"
        end

      {:ok, other} ->
        raise ArgumentError,
              "config :lemon_core, :services must be a list of service groups, got: " <>
                inspect(other)
    end
  end

  # Only a runtime boot is a product boot; one-shot clients never require
  # capabilities.
  defp check_capabilities(:runtime, groups) do
    case LemonCore.Capabilities.check(LemonCore.Capabilities.required(), groups) do
      :ok ->
        :ok

      {:error, {:missing_capability, capability, reason}} ->
        Logger.error(
          "lemon_core refuses to start: this product requires the " <>
            "#{inspect(capability)} capability, but #{reason}"
        )

        {:error, {:missing_capability, capability}}
    end
  end

  defp check_capabilities(_client_mode, _groups), do: :ok

  @doc false
  @spec children(:runtime | :client | :read_only_client, [service_group()]) :: [
          Supervisor.child_spec() | module() | tuple()
        ]
  def children(mode, groups \\ service_groups())
      when mode in [:runtime, :client, :read_only_client] do
    for {group, child} <- grouped_children(mode, groups), group in groups, do: child
  end

  defp grouped_children(mode, groups) do
    runtime? = mode == :runtime
    config_cache_opts = Application.get_env(:lemon_core, LemonCore.ConfigCache, [])

    store =
      case mode do
        :runtime -> LemonCore.Store
        :client -> {LemonCore.Store, sweep: false}
        :read_only_client -> {LemonCore.Store, sweep: false, read_only: true}
      end

    [
      core: LemonCore.RuntimeCache,
      core: LemonCore.RuntimeLatch,
      core: {DynamicSupervisor, strategy: :one_for_one, name: LemonCore.Dedupe.Supervisor},
      core: LemonCore.Bus.child_spec_for_backend()
    ] ++
      if(runtime?, do: [runtime_control: LemonCore.Drain], else: []) ++
      [
        runtime_control: LemonCore.ACPClientBridge,
        runtime_control: LemonCore.NodeRegistry,
        core: {LemonCore.ConfigCache, config_cache_opts},
        core: store
      ] ++
      if(runtime?,
        do: [runtime_control: LemonCore.RuntimeOwner, runtime_control: LemonCore.TerminalOutbox],
        else: []
      ) ++
      [
        runtime_control: LemonCore.SessionActivity,
        core: LemonCore.Secrets.Usage,
        runtime_control: LemonCore.UsageLedger,
        runtime_control: {LemonCore.ExecApprovalExpiry, recover: runtime?},
        core: LemonCore.TaskSupervisor.child_spec(name: LemonCore.Secrets.SourceTaskSupervisor),
        core: LemonCore.Secrets.SourceCache
      ] ++
      if(runtime? and :run_history in groups, do: run_history_children(), else: []) ++
      if(runtime?,
        do: [
          runtime_control: LemonCore.ConfigReloader,
          runtime_control: LemonCore.ConfigReloader.Watcher
        ],
        else: []
      )
  end

  # RunHistoryStore needs the SQLite NIF. `:exqlite` is an optional dependency,
  # so without it the rest of lemon_core still boots and run history is
  # unavailable: a product that needs it requires the :run_history capability.
  defp run_history_children do
    if Code.ensure_loaded?(Exqlite.Sqlite3) do
      [run_history: LemonCore.RunHistoryStore]
    else
      Logger.warning(
        "exqlite is not available, so LemonCore.RunHistoryStore was not started: " <>
          "run history is unavailable (LemonCore.RunHistoryStore.fetch/2 returns " <>
          "{:error, :unavailable} and finalize-run hooks that persist history do " <>
          "nothing). Durable memory has the same requirement in lemon_memory. " <>
          ":exqlite is an optional dependency of lemon_core, so declare it yourself " <>
          "to enable these: {:exqlite, \"~> 0.34\"}. A product that cannot run " <>
          "without run history should require it: config :lemon_core, " <>
          ":required_capabilities, [:run_history]."
      )

      []
    end
  end

  # `:logger` handlers are configured by name (the Sentry handler is only
  # configured when SENTRY_DSN is set). Skip any whose module is missing —
  # sentry is optional, and an unloadable handler module takes the boot down.
  defp drop_unloadable_handlers do
    configured = Application.get_env(:lemon_core, :logger, [])

    {loadable, missing} =
      Enum.split_with(configured, fn
        {:handler, _id, module, _config} -> Code.ensure_loaded?(module)
        _other -> true
      end)

    for {:handler, id, module, _config} <- missing do
      Logger.warning(
        "Skipping :logger handler #{inspect(id)}: #{inspect(module)} is not available. " <>
          "Add the dependency that provides it to enable this handler."
      )
    end

    if missing != [] do
      Application.put_env(:lemon_core, :logger, loadable)
    end

    :ok
  end
end
