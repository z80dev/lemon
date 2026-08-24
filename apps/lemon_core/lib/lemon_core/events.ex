defmodule LemonCore.Events do
  @moduledoc """
  The registry of typed `LemonCore.Bus` payloads — the platform's wire format.

  Each entry maps a `LemonCore.Event` type atom to the module describing its payload.
  Publishing a registered type with a payload that is neither the right struct nor a map
  is a bug; `LemonCore.Bus.broadcast_event/4` catches it in `:dev` and `:test`.

  Full catalog, migration order and the versioning rules live in
  `docs/platform/bus-events.md` in the Lemon repository.

  ## Scope

  Only *platform contract* topics are registered — those whose payload crosses an app
  boundary or reaches the control plane and its clients: `run:<id>`, `session:<key>`,
  `exec_approvals`, `cron`, `system`, `goals`, `routing_feedback`, `channels`.

  Topics whose publisher and every subscriber live in one app (`nodes`, `presence`,
  `run_graph:*`, `parent_question:*`, and the sim/arena family) are deliberately absent.
  Their shapes are documented in their owning app; giving them core structs would push
  domain types back into `lemon_core`.

  ## Compatibility

  Payload structs do **not** implement `Access`: `payload[:key]` raises, and a consumer reads
  a field or pattern-matches the struct. A consumer that may still be handed a legacy map —
  one relaying events from another node, or reading an event injected through the control
  plane's `events.ingest` — coerces once at its entry point with `coerce/2`, rather than
  carrying key-probing downstream into the code that reads the payload:

      def handle_info(%LemonCore.Event{type: :run_completed, payload: payload}, state) do
        %Events.RunCompleted{completed: completed} = coerce(:run_completed, payload)
        ...
      end

  `from_map/1` on every payload module is what makes that safe: it accepts string keys, drops
  unknown ones, and coerces nested payloads. `cast/2` is the strict counterpart for trust
  boundaries, where a malformed payload should be refused with a reason rather than relayed.
  """

  alias LemonCore.Events

  @registry %{
    # run:<run_id> — also forwarded to session:<session_key>
    run_started: Events.RunStarted,
    delta: Events.Delta,
    run_completed: Events.RunCompleted,
    run_failed: Events.RunFailed,
    run_phase_changed: Events.RunPhaseChanged,
    engine_action: Events.EngineAction,

    # exec_approvals
    approval_requested: Events.ApprovalRequested,
    approval_resolved: Events.ApprovalResolved,

    # cron
    cron_tick: Events.CronTick,
    cron_run_started: Events.CronRunStarted,
    cron_run_completed: Events.CronRunCompleted,
    cron_job_created: Events.CronJobChanged,
    cron_job_updated: Events.CronJobChanged,
    cron_job_deleted: Events.CronJobChanged,
    cron_lifecycle_action: Events.CronLifecycleAction,
    heartbeat_alert: Events.HeartbeatAlert,
    heartbeat_suppressed: Events.HeartbeatSuppressed,

    # system
    config_reloaded: Events.ConfigReloaded,
    config_reload_failed: Events.ConfigReloadFailed,
    secret_changed: Events.SecretChanged,
    talk_mode_changed: Events.TalkModeChanged,

    # goals — also published on session:<session_key>
    goal_set: Events.GoalChanged,
    goal_paused: Events.GoalChanged,
    goal_resumed: Events.GoalChanged,
    goal_completed: Events.GoalChanged,
    goal_cleared: Events.GoalChanged,
    goal_continuation_submitted: Events.GoalChanged,
    goal_loop_verdict: Events.GoalChanged,
    goal_loop_status: Events.GoalChanged,

    # routing_feedback
    routing_feedback: Events.RoutingFeedback,

    # channels
    channel_delivery: Events.ChannelDelivery
  }

  @nested [Events.Completion, Events.Action, Events.ApprovalPending]

  @doc """
  Event type atom to payload module.
  """
  @spec registry() :: %{atom() => module()}
  def registry, do: @registry

  @doc """
  Payload modules that are only ever nested inside another payload, never published alone.
  """
  @spec nested_modules() :: [module()]
  def nested_modules, do: @nested

  @doc """
  Every payload module, published or nested.
  """
  @spec modules() :: [module()]
  def modules, do: Enum.uniq(Map.values(@registry) ++ @nested)

  @doc """
  The payload module for an event type, or `nil` if the type is not part of the contract.
  """
  @spec payload_module(atom()) :: module() | nil
  def payload_module(type) when is_atom(type), do: Map.get(@registry, type)

  @doc """
  Whether an event type is part of the typed platform contract.
  """
  @spec registered?(atom()) :: boolean()
  def registered?(type) when is_atom(type), do: Map.has_key?(@registry, type)

  @doc """
  Coerce a payload to its registered struct, leaving unregistered types untouched.

  Consumers use this to accept both the struct and the legacy map during the migration:

      payload = LemonCore.Events.coerce(:run_completed, event.payload)
  """
  @spec coerce(atom(), term()) :: term()
  def coerce(type, payload) do
    case payload_module(type) do
      nil -> payload
      module -> coerce_with(module, payload)
    end
  end

  defp coerce_with(module, payload) when is_map(payload) do
    if is_struct(payload, module), do: payload, else: module.from_map(payload)
  rescue
    # A payload that cannot be coerced is malformed — most likely injected through the
    # control-plane event methods. Hand it back untouched so the consumer's own
    # defensive handling decides, rather than crashing the subscriber.
    _ -> payload
  end

  defp coerce_with(_module, payload), do: payload

  @doc """
  Coerce a payload to its registered struct, reporting why if it cannot be.

  The strict counterpart to `coerce/2`. Use it at trust boundaries — anywhere a payload
  arrives from outside the process that will publish it — so a malformed payload is refused
  with a reason rather than broadcast as-is. Unregistered types pass through unchanged: they
  have no declared shape to validate against.

      iex> LemonCore.Events.cast(:secret_changed, %{"owner" => "u", "name" => "k", "action" => "put"})
      {:ok, %LemonCore.Events.SecretChanged{owner: "u", name: "k", action: "put"}}

      iex> {:error, reason} = LemonCore.Events.cast(:secret_changed, %{"owner" => "u"})
      iex> reason =~ "SecretChanged"
      true
  """
  @spec cast(atom(), term()) :: {:ok, term()} | {:error, String.t()}
  def cast(type, payload) do
    case payload_module(type) do
      nil -> {:ok, payload}
      module -> cast_with(module, payload)
    end
  end

  defp cast_with(module, payload) when is_map(payload) do
    if is_struct(payload, module) do
      {:ok, payload}
    else
      {:ok, module.from_map(payload)}
    end
  rescue
    error -> {:error, "#{inspect(module)} rejected the payload: #{Exception.message(error)}"}
  end

  defp cast_with(module, payload) do
    {:error, "#{inspect(module)} requires a map payload, got: #{inspect(payload, limit: 5)}"}
  end
end
