defmodule LemonControlPlane.EventBridge do
  @moduledoc """
  Bridges events from LemonCore.Bus to WebSocket clients.

  This GenServer subscribes to relevant bus topics and forwards events
  to connected non-node WebSocket clients as event frames. Authenticated nodes
  receive only traffic sent directly to their connection as targeted
  `{:node_event, event_name, payload}` messages.

  ## Topics Subscribed

  - `run:*` - Run lifecycle events (agent, chat events, task lifecycle)
  - `session:*` - Session lifecycle and task events
  - `channels` - Channel-related events
  - `exec_approvals` - Approval request/resolution events
  - `cron` - Cron job events
  - `goals` - Durable goal lifecycle events
  - `system` - System events (shutdown, health, tick)
  - `nodes` - Node pairing events
  - `presence` - Presence events
  - `omp` (`LemonOmp.bus_topic/0`) - omp delegate session snapshots

  ## Event Mapping

  Bus events are mapped to control-plane event names:

  | Bus Event                | WS Event                  |
  |--------------------------|---------------------------|
  | :run_started             | agent                     |
  | :run_completed           | agent                     |
  | :delta                   | chat                      |
  | :engine_action           | agent (type: tool_use)    |
  | :checkpoint_created      | agent (type: checkpoint_created) |
  | :checkpoint_restored     | agent (type: checkpoint_restored) |
  | :checkpoint_deleted      | agent (type: checkpoint_deleted) |
  | :goal_set                | goal                      |
  | :goal_paused             | goal                      |
  | :goal_resumed            | goal                      |
  | :goal_completed          | goal                      |
  | :goal_cleared            | goal                      |
  | :goal_continuation_submitted | goal                  |
  | :goal_loop_verdict       | goal                      |
  | :goal_loop_status        | goal                      |
  | :approval_requested      | exec.approval.requested   |
  | :approval_resolved       | exec.approval.resolved    |
  | :channel_delivery        | channel.delivery          |
  | :cron_run_started        | cron                      |
  | :cron_run_completed      | cron                      |
  | :cron_lifecycle_action   | cron.audit                |
  | :cron_tick               | tick                      |
  | :tick                    | tick                      |
  | :presence_changed        | presence                  |
  | :heartbeat               | heartbeat                 |
  | :heartbeat_alert         | heartbeat                 |
  | :metrics                 | metrics                   |
  | :log                     | log                       |
  | :node_pair_requested     | node.pair.requested       |
  | :node_pair_resolved      | node.pair.resolved        |
  | :node_invoke_request     | node.invoke.request       |
  | :node_invoke_completed   | node.invoke.completed     |
  | :shutdown                | shutdown                  |
  | :health_changed          | health                    |
  | :task_started            | task.started              |
  | :task_completed          | task.completed            |
  | :task_error              | task.error                |
  | :task_timeout            | task.timeout              |
  | :task_aborted            | task.aborted              |
  | :run_graph_changed       | run.graph.changed         |
  | :omp_session             | omp.session               |
  """

  use GenServer

  require Logger

  alias LemonControlPlane.Presence
  alias LemonCore.Bus
  alias LemonCore.Bus.Delivery
  alias LemonCore.Events

  @bus_topics [
    "exec_approvals",
    "user_prompts",
    "channels",
    "cron",
    "goals",
    "system",
    "nodes",
    "presence"
  ]

  # State version tracking for client reconciliation
  @state_version_keys [:presence, :health, :cron]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribe to run events for a specific run_id.
  """
  def subscribe_run(run_id) do
    subscribe_topics(["run:#{run_id}"])
  end

  @doc """
  Unsubscribe from run events.
  """
  def unsubscribe_run(run_id) do
    unsubscribe_topics(["run:#{run_id}"])
  end

  @doc """
  Subscribe the bridge to dynamic bus topics needed by active clients.
  """
  def subscribe_topics(topics) when is_list(topics) do
    GenServer.cast(__MODULE__, {:subscribe_topics, topics})
  end

  @doc """
  Release bridge subscriptions for dynamic bus topics no longer needed.
  """
  def unsubscribe_topics(topics) when is_list(topics) do
    GenServer.cast(__MODULE__, {:unsubscribe_topics, topics})
  end

  @impl true
  def init(_opts) do
    delivery = Delivery.new(self(), tagged: true)
    Enum.each([LemonOmp.bus_topic() | @bus_topics], &Bus.subscribe(&1, delivery: delivery))

    # Initialize state version counters
    state_versions = Map.new(@state_version_keys, fn key -> {key, 0} end)

    {:ok,
     %{
       run_subscriptions: MapSet.new(),
       topic_ref_counts: %{},
       state_versions: state_versions,
       delivery: delivery
     }}
  end

  @impl true
  def handle_cast({:subscribe_topics, topics}, state) do
    state =
      topics
      |> Enum.filter(&dynamic_topic?/1)
      |> Enum.reduce(state, &subscribe_dynamic_topic/2)

    {:noreply, state}
  end

  def handle_cast({:unsubscribe_topics, topics}, state) do
    state =
      topics
      |> Enum.filter(&dynamic_topic?/1)
      |> Enum.reduce(state, &unsubscribe_dynamic_topic/2)

    {:noreply, state}
  end

  @impl true
  def handle_info({:lemon_bus_delivery, gate, message}, state) do
    if Delivery.matches?(state.delivery, gate),
      do: handle_info(message, state),
      else: {:noreply, state}
  end

  def handle_info({:stream_resync, :overflow}, state) do
    # Lost bus deltas cannot be replayed. Fence every affected client and require
    # authenticated reconnect + owner snapshot recovery, including approvals.
    for {_id, info} <- get_connected_clients(), general_event_client?(info) do
      Delivery.resync(info.delivery)
    end

    topics = [LemonOmp.bus_topic() | @bus_topics] ++ Map.keys(state.topic_ref_counts)
    Enum.each(topics, &Bus.unsubscribe/1)
    delivery = Delivery.new(self(), tagged: true)
    Enum.each(topics, &Bus.subscribe(&1, delivery: delivery))
    {:noreply, %{state | delivery: delivery}}
  end

  def handle_info(%LemonCore.Event{} = event, state) do
    {state, state_version} = maybe_bump_state_version(state, event.type)
    broadcast_event(event, state_version)
    {:noreply, state}
  end

  # Handle raw map events (fallback)
  def handle_info(%{type: type} = event, state) when is_atom(type) do
    {state, state_version} = maybe_bump_state_version(state, type)
    broadcast_event(event, state_version)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Bump state version for events that affect state reconciliation
  defp maybe_bump_state_version(state, event_type) do
    version_key = state_version_key_for(event_type)

    if version_key do
      new_versions = Map.update!(state.state_versions, version_key, &(&1 + 1))
      {%{state | state_versions: new_versions}, new_versions}
    else
      {state, state.state_versions}
    end
  end

  defp state_version_key_for(:presence_changed), do: :presence
  defp state_version_key_for(:health_changed), do: :health
  defp state_version_key_for(:cron_tick), do: :cron
  defp state_version_key_for(:cron_run_started), do: :cron
  defp state_version_key_for(:cron_run_completed), do: :cron
  defp state_version_key_for(:cron_lifecycle_action), do: :cron
  defp state_version_key_for(:cron_job_created), do: :cron
  defp state_version_key_for(:cron_job_updated), do: :cron
  defp state_version_key_for(:cron_job_deleted), do: :cron
  defp state_version_key_for(_), do: nil

  # Broadcast an event to all connected clients
  defp broadcast_event(event, state_version) do
    case project(event) do
      nil ->
        :ok

      {event_name, payload} ->
        clients =
          get_connected_clients()
          |> Enum.filter(fn {_conn_id, info} -> general_event_client?(info) end)

        dispatch_event(clients, event_name, payload, state_version)
    end
  end

  defp general_event_client?(%{role: role})
       when role in [:node, "node", :enrollment, "enrollment"], do: false

  defp general_event_client?(_info), do: true

  defp dispatch_event(clients, event_name, payload, state_version) do
    payload_meta = %{event: event_name, recipients: length(clients)}

    LemonCore.Telemetry.emit(
      [:lemon, :control_plane, :event_bridge, :broadcast],
      %{count: 1, recipients: length(clients)},
      payload_meta
    )

    # Inline admission is nonblocking and preserves event order. A task per event
    # simply moved an unbounded queue into the task supervisor.
    Enum.each(clients, fn {_conn_id, info} ->
      Delivery.send(info.delivery, {:event, event_name, payload, state_version})
    end)
  end

  defp dynamic_topic?(topic) when is_binary(topic) do
    String.starts_with?(topic, "run:") || String.starts_with?(topic, "session:")
  end

  defp dynamic_topic?(_), do: false

  defp subscribe_dynamic_topic(topic, state) do
    count = Map.get(state.topic_ref_counts, topic, 0)

    if count == 0 do
      Bus.subscribe(topic, delivery: state.delivery)
    end

    ref_counts = Map.put(state.topic_ref_counts, topic, count + 1)
    %{state | topic_ref_counts: ref_counts, run_subscriptions: run_subscription_set(ref_counts)}
  end

  defp unsubscribe_dynamic_topic(topic, state) do
    case Map.get(state.topic_ref_counts, topic, 0) do
      count when count > 1 ->
        ref_counts = Map.put(state.topic_ref_counts, topic, count - 1)

        %{
          state
          | topic_ref_counts: ref_counts,
            run_subscriptions: run_subscription_set(ref_counts)
        }

      1 ->
        Bus.unsubscribe(topic)
        ref_counts = Map.delete(state.topic_ref_counts, topic)

        %{
          state
          | topic_ref_counts: ref_counts,
            run_subscriptions: run_subscription_set(ref_counts)
        }

      _ ->
        state
    end
  end

  defp run_subscription_set(ref_counts) do
    ref_counts
    |> Map.keys()
    |> Enum.filter(&String.starts_with?(&1, "run:"))
    |> Enum.map(&String.replace_prefix(&1, "run:", ""))
    |> MapSet.new()
  end

  defp get_connected_clients do
    case Process.whereis(Presence) do
      nil -> []
      _ -> Presence.list()
    end
  rescue
    _ -> []
  end

  @doc """
  Projects one Bus event to its operator wire event, `{event_name, payload}`,
  or `nil` when the event has no operator projection.

  This is the single projection used for WebSocket fanout; in-process operator
  clients (the web UI) subscribe to the Bus themselves and call it so they see
  exactly the bounded payloads a WebSocket client would.
  """
  @spec project(term()) :: {String.t(), map()} | nil
  # Registered platform payloads are coerced to their struct once, here, so that every clause
  # below can pattern-match one: a struct passes through untouched and a legacy map — such
  # as a hand-built test payload — becomes its struct. A payload too malformed to coerce
  # stays a map, misses its typed clause and is reported by the catch-all, instead of being
  # fanned out to clients as a frame of nils.
  #
  # `meta` is deliberately still a free map (see docs/platform/bus-events.md §4.1), so it is
  # read with `Access`; the payload never is.
  def project(%LemonCore.Event{type: type, payload: payload, meta: meta}) do
    map_event_type(type, Events.coerce(type, payload), meta || %{})
  end

  def project(%{type: type, payload: payload} = event) do
    map_event_type(type, Events.coerce(type, payload), Map.get(event, :meta) || %{})
  end

  def project(_), do: nil

  defp map_event_type(:stream_resync, _payload, meta) do
    {"stream.resync",
     %{
       "reason" => "overflow",
       "sessionKey" => meta[:session_key],
       "runId" => meta[:run_id]
     }}
  end

  # Run events
  defp map_event_type(:run_started, %Events.RunStarted{} = payload, meta) do
    # The resolved model is only ever observable here — nothing persists it — so the provider
    # is looked up now rather than left for the client to infer from the id.
    model = normalize_event_string(payload.model) || normalize_event_string(meta[:model])

    {"agent",
     %{
       "type" => "started",
       "runId" => payload.run_id || meta[:run_id],
       "sessionKey" => payload.session_key || meta[:session_key],
       "engine" => "lemon",
       "parentRunId" => meta[:parent_run_id],
       "model" => model,
       "provider" =>
         normalize_event_string(payload.provider) ||
           LemonControlPlane.SessionModel.provider_for(model),
       "thinkingLevel" =>
         normalize_event_string(payload.thinking_level) ||
           normalize_event_string(meta[:thinking_level])
     }}
  end

  defp map_event_type(:run_completed, %Events.RunCompleted{} = payload, meta) do
    # Every publisher and `RunCompleted.from_map/1` put a `Events.Completion` here, but a
    # payload built with `new/1` from a raw nested map keeps that map, so the nested reads go
    # through `get_field/2` — struct-and-map safe, and not `Access`.
    completed = payload.completed
    model = normalize_event_string(meta[:model])

    {"agent",
     %{
       "type" => "completed",
       "runId" => meta[:run_id],
       "sessionKey" => meta[:session_key],
       "ok" => get_field(completed, :ok),
       "cancelled" => get_field(get_field(completed, :meta) || %{}, :cancelled) == true,
       "error" => LemonControlPlane.EventProjection.action_detail(get_field(completed, :error)),
       "answer" => truncate(get_field(completed, :answer), 500),
       "durationMs" => payload.duration_ms,
       "usage" => LemonControlPlane.UsageTokens.normalize(get_field(completed, :usage)),
       "model" => model
     }}
  end

  defp map_event_type(:delta, %Events.Delta{} = payload, meta) do
    {"chat",
     %{
       "type" => "delta",
       "runId" => payload.run_id || meta[:run_id],
       "sessionKey" => meta[:session_key],
       "seq" => payload.seq,
       "text" => payload.text
     }}
  end

  # Engine action events (tool_use)
  defp map_event_type(:engine_action, %Events.EngineAction{} = payload, meta) do
    action = payload.action

    {"agent",
     %{
       "type" => "tool_use",
       "runId" => get_field(meta, :run_id),
       "sessionKey" => get_field(meta, :session_key),
       "action" => %{
         "id" => get_field(action, :id),
         "kind" => get_field(action, :kind),
         "title" => get_field(action, :title),
         "detail" => operator_action_detail(get_field(action, :detail))
       },
       "phase" => payload.phase,
       "ok" => payload.ok,
       "message" => payload.message
     }}
  end

  defp map_event_type(type, payload, meta)
       when type in [:checkpoint_created, :checkpoint_restored, :checkpoint_deleted] do
    {"agent",
     %{
       "type" => Atom.to_string(type),
       "runId" => get_field(meta, :run_id),
       "sessionKey" => get_field(meta, :session_key),
       "checkpointId" => get_field(payload, :checkpoint_id),
       "checkpointKind" => get_field(payload, :checkpoint_kind),
       "tool" => get_field(payload, :tool),
       "action" => get_field(payload, :action),
       "pathCount" => get_field(payload, :path_count),
       "paths" => get_field(payload, :paths),
       "restoredCount" => get_field(payload, :restored_count)
     }}
  end

  defp map_event_type(type, %Events.GoalChanged{} = payload, meta)
       when type in [
              :goal_set,
              :goal_paused,
              :goal_resumed,
              :goal_completed,
              :goal_cleared,
              :goal_continuation_submitted,
              :goal_loop_verdict,
              :goal_loop_status
            ] do
    {"goal",
     %{
       "type" => Atom.to_string(type),
       "sessionKey" => get_field(meta, :session_key) || payload.session_key,
       "goalId" => payload.goal_id,
       "agentId" => payload.agent_id,
       "status" => payload.status,
       "objectiveBytes" => payload.objective_bytes,
       "continuationCount" => payload.continuation_count,
       "lastRunId" => payload.last_run_id,
       "loopStatus" => payload.loop_status,
       "loopVerdict" => payload.loop_verdict
     }}
  end

  # Approval events
  #
  # `pending` is an `Events.ApprovalPending` from every publisher, but is read with
  # `get_field/2` for the same reason as `RunCompleted`'s `completed`.
  defp map_event_type(:approval_requested, %Events.ApprovalRequested{} = payload, _meta) do
    pending = payload.pending

    {"exec.approval.requested",
     %{
       "approvalId" => get_field(pending, :id) || payload.approval_id,
       "runId" => get_field(pending, :run_id),
       "sessionKey" => get_field(pending, :session_key),
       "agentId" => get_field(pending, :agent_id),
       "tool" => get_field(pending, :tool),
       "action" => stringify_keys(LemonCore.Redact.map(get_field(pending, :action) || %{})),
       "rationale" => LemonCore.Redact.text(get_field(pending, :rationale)),
       "requestedAtMs" => get_field(pending, :requested_at_ms),
       "expiresAtMs" => get_field(pending, :expires_at_ms)
     }}
  end

  defp map_event_type(:approval_resolved, %Events.ApprovalResolved{} = payload, meta) do
    pending = payload.pending

    {"exec.approval.resolved",
     %{
       "approvalId" => payload.approval_id,
       "decision" => to_string(payload.decision || :resolved),
       "runId" => get_field(pending, :run_id) || get_field(meta, :run_id),
       "sessionKey" => get_field(pending, :session_key) || get_field(meta, :session_key),
       "agentId" => get_field(pending, :agent_id),
       "tool" => get_field(pending, :tool)
     }}
  end

  defp map_event_type(:user_prompt_requested, payload, _meta) when is_map(payload),
    do:
      {"session.prompt.requested",
       Map.take(payload, [
         "promptId",
         "sessionKey",
         "runId",
         "questions",
         "requestedAtMs",
         "expiresAtMs"
       ])}

  defp map_event_type(:user_prompt_resolved, payload, _meta) when is_map(payload),
    do:
      {"session.prompt.resolved",
       Map.take(payload, ["promptId", "sessionKey", "runId", "status"])}

  # Channel delivery events — outbound dispatch observations from LemonChannels.Dispatcher.
  defp map_event_type(:channel_delivery, %Events.ChannelDelivery{} = payload, meta) do
    {"channel.delivery",
     %{
       "intentId" => payload.intent_id,
       "runId" => payload.run_id || get_field(meta, :run_id),
       "sessionKey" => payload.session_key || get_field(meta, :session_key),
       "channelId" => payload.channel_id,
       "accountId" => payload.account_id,
       "peerKind" => normalize_atom_or_binary(payload.peer_kind),
       "peerId" => payload.peer_id,
       "threadId" => payload.thread_id,
       "kind" => normalize_atom_or_binary(payload.kind),
       "textPreview" => truncate(payload.text_preview, 500),
       "ok" => payload.ok,
       "error" => payload.error,
       "durationMs" => payload.duration_ms,
       "tsMs" => payload.ts_ms
     }}
  end

  # Cron events
  #
  # The payloads carry the flat fields this mapping needs; their `run`/`job` records are the
  # pre-3.1 nested shape, kept on the struct for consumers that want the whole record.
  defp map_event_type(:cron_run_started, %Events.CronRunStarted{} = payload, _meta) do
    {"cron",
     %{
       "type" => "started",
       "runId" => payload.router_run_id,
       "cronRunId" => payload.cron_run_id,
       "jobId" => payload.job_id,
       "jobName" => payload.job_name,
       "agentId" => payload.agent_id,
       "sessionKey" => payload.session_key,
       "triggeredBy" => to_string(payload.triggered_by || :schedule),
       "startedAtMs" => payload.started_at_ms
     }}
  end

  defp map_event_type(:cron_run_completed, %Events.CronRunCompleted{} = payload, _meta) do
    {"cron",
     %{
       "type" => "completed",
       "runId" => payload.router_run_id,
       "cronRunId" => payload.cron_run_id,
       "jobId" => payload.job_id,
       "status" => to_string(payload.status),
       "suppressed" => payload.suppressed || false,
       "agentId" => payload.agent_id,
       "sessionKey" => payload.session_key,
       "durationMs" => payload.duration_ms,
       "error" => payload.error
     }}
  end

  defp map_event_type(:cron_lifecycle_action, %Events.CronLifecycleAction{} = payload, _meta) do
    audit = payload.audit

    {"cron.audit",
     %{
       "type" => get_field(audit, :action),
       "auditId" => get_field(audit, :id),
       "jobId" => get_field(audit, :job_id),
       "cronRunId" => get_field(audit, :run_id),
       "runId" => get_field(audit, :router_run_id) || get_field(audit, :run_id),
       "source" => get_field(audit, :source),
       "status" => get_field(audit, :status),
       "triggeredBy" => get_field(audit, :triggered_by),
       "reason" => get_field(audit, :reason),
       "changedFields" => get_field(audit, :changed_fields) || [],
       "tsMs" => get_field(audit, :ts_ms)
     }}
  end

  defp map_event_type(:cron_job_created, %Events.CronJobChanged{} = payload, _meta) do
    map_cron_job_event("created", payload)
  end

  defp map_event_type(:cron_job_updated, %Events.CronJobChanged{} = payload, _meta) do
    map_cron_job_event("updated", payload)
  end

  defp map_event_type(:cron_job_deleted, %Events.CronJobChanged{} = payload, _meta) do
    {"cron.job",
     %{
       "type" => "deleted",
       "jobId" => payload.job_id,
       "name" => payload.name
     }}
  end

  # Tick events - handle both :tick and :cron_tick
  defp map_event_type(:tick, payload, _meta) do
    timestamp = extract_timestamp(payload)
    {"tick", %{"timestampMs" => timestamp}}
  end

  defp map_event_type(:cron_tick, %Events.CronTick{} = payload, _meta) do
    {"tick", %{"timestampMs" => payload.timestamp_ms}}
  end

  # Presence events
  defp map_event_type(:presence_changed, payload, _meta) do
    {"presence",
     %{
       "connections" => payload[:connections] || [],
       "count" => payload[:count] || 0
     }}
  end

  # Heartbeat events
  defp map_event_type(:heartbeat, payload, _meta) do
    {"heartbeat",
     %{
       "agentId" => payload[:agent_id],
       "status" => to_string(payload[:status] || :ok),
       "timestampMs" => payload[:timestamp_ms] || System.system_time(:millisecond)
     }}
  end

  defp map_event_type(:heartbeat_alert, %Events.HeartbeatAlert{} = payload, _meta) do
    {"heartbeat",
     %{
       "agentId" => payload.agent_id,
       "status" => "alert",
       "response" => payload.response,
       "timestampMs" => System.system_time(:millisecond)
     }}
  end

  defp map_event_type(:heartbeat_suppressed, %Events.HeartbeatSuppressed{} = payload, _meta) do
    {"heartbeat",
     %{
       "agentId" => payload.agent_id,
       "status" => "suppressed",
       "runId" => payload.run_id,
       "jobId" => payload.job_id,
       "timestampMs" => System.system_time(:millisecond)
     }}
  end

  defp map_event_type(:metrics, payload, meta) do
    {"metrics",
     add_target_fields(
       %{
         "payload" => stringify_keys(payload || %{}),
         "timestampMs" => System.system_time(:millisecond)
       },
       meta
     )}
  end

  defp map_event_type(:log, payload, meta) do
    {"log",
     add_target_fields(
       %{
         "level" => get_field(payload, :level),
         "message" => truncate(get_field(payload, :message), 500),
         "timestampMs" => get_field(payload, :timestamp_ms) || System.system_time(:millisecond)
       },
       meta
     )}
  end

  # Node events
  defp map_event_type(:node_pair_requested, payload, _meta) do
    {"node.pair.requested",
     %{
       "pairingId" => payload[:pairing_id],
       "code" => payload[:code],
       "nodeType" => payload[:node_type],
       "nodeName" => payload[:node_name],
       "expiresAtMs" => payload[:expires_at_ms]
     }}
  end

  defp map_event_type(:node_pair_resolved, payload, _meta) do
    {"node.pair.resolved",
     %{
       "pairingId" => payload[:pairing_id],
       "nodeId" => payload[:node_id],
       "approved" => payload[:approved] || false,
       "rejected" => payload[:rejected] || false
     }}
  end

  defp map_event_type(:node_invoke_request, payload, _meta) do
    {"node.invoke.request",
     %{
       "invokeId" => payload[:invoke_id],
       "nodeId" => payload[:node_id],
       "method" => payload[:method],
       "timeoutMs" => payload[:timeout_ms],
       "cleanup" => %{"includesArgs" => false}
     }}
  end

  defp map_event_type(:node_invoke_completed, payload, _meta) do
    {"node.invoke.completed",
     %{
       "invokeId" => payload[:invoke_id],
       "nodeId" => payload[:node_id],
       "ok" => payload[:ok],
       "resultSummary" => stringify_keys(payload[:result_summary] || %{}),
       "errorSummary" => stringify_keys(payload[:error_summary] || %{}),
       "cleanup" => %{
         "includesResult" => false,
         "includesError" => false
       }
     }}
  end

  # System events
  defp map_event_type(:shutdown, payload, _meta) do
    {"shutdown", payload}
  end

  defp map_event_type(:health_changed, payload, _meta) do
    {"health", payload}
  end

  # Task lifecycle events
  defp map_event_type(:task_started, payload, meta) do
    {"task.started",
     %{
       "taskId" => payload[:task_id] || meta[:task_id],
       "parentRunId" => payload[:parent_run_id] || meta[:parent_run_id],
       "runId" => payload[:run_id] || meta[:run_id],
       "sessionKey" => payload[:session_key] || meta[:session_key],
       "agentId" => payload[:agent_id] || meta[:agent_id],
       "startedAtMs" => payload[:started_at_ms] || System.system_time(:millisecond),
       "description" => payload[:description],
       "engine" => payload[:engine],
       "role" => payload[:role]
     }}
  end

  defp map_event_type(:task_completed, payload, meta) do
    {"task.completed",
     %{
       "taskId" => payload[:task_id] || meta[:task_id],
       "parentRunId" => payload[:parent_run_id] || meta[:parent_run_id],
       "runId" => payload[:run_id] || meta[:run_id],
       "sessionKey" => payload[:session_key] || meta[:session_key],
       "agentId" => payload[:agent_id] || meta[:agent_id],
       "ok" => payload[:ok],
       "durationMs" => payload[:duration_ms],
       "resultPreview" => payload[:result_preview],
       "description" => payload[:description],
       "completedAtMs" => payload[:completed_at_ms] || System.system_time(:millisecond)
     }}
  end

  defp map_event_type(:task_error, payload, meta) do
    {"task.error",
     %{
       "taskId" => payload[:task_id] || meta[:task_id],
       "parentRunId" => payload[:parent_run_id] || meta[:parent_run_id],
       "runId" => payload[:run_id] || meta[:run_id],
       "sessionKey" => payload[:session_key] || meta[:session_key],
       "agentId" => payload[:agent_id] || meta[:agent_id],
       "error" => payload[:error],
       "durationMs" => payload[:duration_ms],
       "description" => payload[:description]
     }}
  end

  defp map_event_type(:task_timeout, payload, meta) do
    {"task.timeout",
     %{
       "taskId" => payload[:task_id] || meta[:task_id],
       "parentRunId" => payload[:parent_run_id] || meta[:parent_run_id],
       "runId" => payload[:run_id] || meta[:run_id],
       "sessionKey" => payload[:session_key] || meta[:session_key],
       "agentId" => payload[:agent_id] || meta[:agent_id],
       "timeoutMs" => payload[:timeout_ms]
     }}
  end

  defp map_event_type(:task_aborted, payload, meta) do
    {"task.aborted",
     %{
       "taskId" => payload[:task_id] || meta[:task_id],
       "parentRunId" => payload[:parent_run_id] || meta[:parent_run_id],
       "runId" => payload[:run_id] || meta[:run_id],
       "sessionKey" => payload[:session_key] || meta[:session_key],
       "agentId" => payload[:agent_id] || meta[:agent_id],
       "reason" => payload[:reason]
     }}
  end

  defp map_event_type(:run_graph_changed, payload, meta) do
    {"run.graph.changed",
     %{
       "runId" => payload[:run_id] || meta[:run_id],
       "parentRunId" => payload[:parent_run_id] || meta[:parent_run_id],
       "sessionKey" => payload[:session_key] || meta[:session_key],
       "status" => normalize_atom_or_binary(payload[:status]),
       "event" => payload[:event],
       "timestampMs" => payload[:timestamp_ms] || System.system_time(:millisecond)
     }}
  end

  # omp delegate snapshots are already bounded, JSON-safe wire maps (`LemonOmp`
  # projects them); forward them unchanged.
  defp map_event_type(:omp_session, %{"reason" => reason, "session" => session}, _meta)
       when is_binary(reason) and is_map(session) do
    {"omp.session", %{"reason" => reason, "session" => session}}
  end

  # Catch-all for unmapped events.
  #
  # Dropping silently is intentional for app-internal and custom event types, but a type in
  # `LemonCore.Events.registry/0` is part of the platform contract: it is published onto a
  # topic this bridge subscribes to, and reaching here means WS clients never see it. Warn
  # once per type so "added an event, forgot the mapping" has a failure mode someone notices.
  #
  # A registered type also lands here when its payload is not — and could not be coerced
  # into — its struct, which is the failure mode the removal of the `Access` shim introduces.
  # The two are worth telling apart in the log, because the fix is different.
  defp map_event_type(type, payload, _meta) do
    if Events.registered?(type), do: warn_unmapped_once(type, payload)
    nil
  end

  # Prefer the operator copies over channel previews, then project only bounded
  # visible data. In particular streaming partial results contain runtime structs.
  defp operator_action_detail(detail) when is_map(detail) and not is_struct(detail) do
    detail
    |> promote_detail_field([:result_full, "result_full"], :result, "result")
    |> promote_reasoning_full_text()
    |> LemonControlPlane.EventProjection.action_detail()
  end

  defp operator_action_detail(detail), do: LemonControlPlane.EventProjection.action_detail(detail)

  defp promote_reasoning_full_text(detail) do
    case take_detail_field(detail, [:reasoning, "reasoning"]) do
      {key, reasoning, _rest} when is_map(reasoning) and not is_struct(reasoning) ->
        Map.put(
          detail,
          key,
          promote_detail_field(reasoning, [:full_text, "full_text"], :text, "text")
        )

      _ ->
        detail
    end
  end

  defp promote_detail_field(map, source_keys, atom_target, string_target) do
    case take_detail_field(map, source_keys) do
      {source_key, value, rest} when is_binary(value) ->
        target = if is_atom(source_key), do: atom_target, else: string_target
        rest |> Map.delete(atom_target) |> Map.delete(string_target) |> Map.put(target, value)

      {_source_key, _value, rest} ->
        rest

      nil ->
        map
    end
  end

  defp take_detail_field(map, keys) do
    Enum.find_value(keys, fn key ->
      if Map.has_key?(map, key), do: {key, Map.get(map, key), Map.delete(map, key)}
    end)
  end

  defp warn_unmapped_once(type, payload) do
    key = {__MODULE__, :unmapped_event, type}

    if :persistent_term.get(key, nil) == nil do
      :persistent_term.put(key, true)
      Logger.warning("[EventBridge] " <> unmapped_reason(type, payload))
    end

    :ok
  end

  defp unmapped_reason(type, payload) do
    module = Events.payload_module(type)

    if is_struct(payload, module) do
      "#{inspect(type)} is a registered platform event with no client mapping; it is being " <>
        "dropped rather than forwarded to WS clients"
    else
      "#{inspect(type)} reached the bridge carrying #{inspect(payload, limit: 5)}, which is " <>
        "not a #{inspect(module)} and could not be coerced into one; it is being dropped " <>
        "rather than forwarded to WS clients. Publish it with Bus.broadcast_event/4."
    end
  end

  # Helper to extract timestamp from various payload formats
  defp extract_timestamp(%{timestamp_ms: ts}), do: ts
  defp extract_timestamp(ts) when is_integer(ts), do: ts
  defp extract_timestamp(_), do: System.system_time(:millisecond)

  # Thinking levels are atoms on the bus and strings on the wire; blank strings become nil so
  # a client can test the key for presence rather than for emptiness.
  defp normalize_event_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_event_string(value) when is_atom(value) and not is_boolean(value) do
    if is_nil(value), do: nil, else: Atom.to_string(value)
  end

  defp normalize_event_string(_), do: nil

  defp truncate(nil, _), do: nil
  defp truncate(text, max) when is_binary(text) and byte_size(text) <= max, do: text
  defp truncate(text, max) when is_binary(text), do: String.slice(text, 0, max) <> "..."
  defp truncate(text, _), do: text

  # Helper to get a field from either a map or a struct
  defp get_field(data, key) when is_struct(data) do
    Map.get(data, key)
  end

  defp get_field(data, key) when is_map(data) do
    cond do
      Map.has_key?(data, key) ->
        Map.get(data, key)

      is_atom(key) and Map.has_key?(data, Atom.to_string(key)) ->
        Map.get(data, Atom.to_string(key))

      true ->
        nil
    end
  end

  defp get_field(_, _), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp add_target_fields(payload, meta) do
    meta
    |> target_fields()
    |> Enum.reduce(payload, fn {key, value}, acc ->
      if is_binary(value) and value != "" do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp target_fields(meta) do
    case get_field(meta || %{}, :target) do
      "run:" <> run_id -> [{"runId", run_id}]
      "session:" <> session_key -> [{"sessionKey", session_key}]
      _ -> []
    end
  end

  defp map_cron_job_event(type, %Events.CronJobChanged{} = payload) do
    job = payload.job

    {"cron.job",
     %{
       "type" => type,
       "jobId" => get_field(job, :id) || payload.job_id,
       "name" => get_field(job, :name),
       "schedule" => get_field(job, :schedule),
       "enabled" => get_field(job, :enabled),
       "agentId" => get_field(job, :agent_id),
       "sessionKey" => get_field(job, :session_key),
       "nextRunAtMs" => get_field(job, :next_run_at_ms)
     }}
  end

  defp normalize_atom_or_binary(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_atom_or_binary(value) when is_binary(value), do: value
  defp normalize_atom_or_binary(value), do: value
end
