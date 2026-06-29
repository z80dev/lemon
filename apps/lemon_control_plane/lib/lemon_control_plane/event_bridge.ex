defmodule LemonControlPlane.EventBridge do
  @moduledoc """
  Bridges events from LemonCore.Bus to WebSocket clients.

  This GenServer subscribes to relevant bus topics and forwards events
  to connected WebSocket clients as event frames.

  ## Topics Subscribed

  - `run:*` - Run lifecycle events (agent, chat events, task lifecycle)
  - `session:*` - Session lifecycle and task events
  - `channels` - Channel-related events
  - `exec_approvals` - Approval request/resolution events
  - `cron` - Cron job events
  - `goals` - Durable goal lifecycle events
  - `system` - System events (shutdown, health, tick, talk.mode)
  - `nodes` - Node pairing events
  - `presence` - Presence events

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
  | :cron_run_started        | cron                      |
  | :cron_run_completed      | cron                      |
  | :cron_lifecycle_action   | cron.audit                |
  | :cron_tick               | tick                      |
  | :tick                    | tick                      |
  | :presence_changed        | presence                  |
  | :talk_mode_changed       | talk.mode                 |
  | :heartbeat               | heartbeat                 |
  | :heartbeat_alert         | heartbeat                 |
  | :metrics                 | metrics                   |
  | :log                     | log                       |
  | :node_pair_requested     | node.pair.requested       |
  | :node_pair_resolved      | node.pair.resolved        |
  | :node_invoke_request     | node.invoke.request       |
  | :node_invoke_completed   | node.invoke.completed     |
  | :device_pair_requested   | device.pair.requested     |
  | :device_pair_resolved    | device.pair.resolved      |
  | :voicewake_changed       | voicewake.changed         |
  | :shutdown                | shutdown                  |
  | :health_changed          | health                    |
  | :custom_event            | custom                    |
  | :task_started            | task.started              |
  | :task_completed          | task.completed            |
  | :task_error              | task.error                |
  | :task_timeout            | task.timeout              |
  | :task_aborted            | task.aborted              |
  | :run_graph_changed       | run.graph.changed         |
  """

  use GenServer

  require Logger

  alias LemonCore.Bus
  alias LemonControlPlane.Presence

  @fanout_supervisor LemonControlPlane.EventBridge.FanoutSupervisor

  @bus_topics [
    "exec_approvals",
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
    # FanoutSupervisor is started by LemonControlPlane.Application supervision tree.
    # No ad hoc startup needed here.

    # Subscribe to static topics
    Enum.each(@bus_topics, &Bus.subscribe/1)

    # Initialize state version counters
    state_versions = Map.new(@state_version_keys, fn key -> {key, 0} end)

    {:ok,
     %{
       run_subscriptions: MapSet.new(),
       topic_ref_counts: %{},
       state_versions: state_versions
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
    case map_event(event) do
      nil ->
        :ok

      {event_name, payload} ->
        # Get all connected clients from presence
        clients =
          get_connected_clients()
          |> filter_subscribed_clients(event_name, payload)

        dispatch_event(clients, event_name, payload, state_version)
    end
  end

  defp filter_subscribed_clients(clients, event_name, payload) do
    Enum.filter(clients, fn {_conn_id, info} ->
      subscribed_to_event?(info, event_name, payload)
    end)
  end

  defp subscribed_to_event?(%{subscription_mode: :custom, subscriptions: subscriptions}, event_name, payload) do
    subscriptions = subscriptions || MapSet.new()

    MapSet.member?(subscriptions, "all") ||
      event_topics(event_name, payload)
      |> Enum.any?(&MapSet.member?(subscriptions, &1))
  end

  defp subscribed_to_event?(_info, _event_name, _payload), do: true

  defp event_topics(event_name, payload) do
    topic_for_event(event_name) ++ run_topics(payload) ++ session_topics(payload)
  end

  defp topic_for_event(event_name) when event_name in ["cron", "cron.job", "cron.audit"],
    do: ["cron"]

  defp topic_for_event("goal"), do: ["goals"]
  defp topic_for_event("tick"), do: ["cron", "system"]
  defp topic_for_event("presence"), do: ["presence"]
  defp topic_for_event("health"), do: ["system"]
  defp topic_for_event("shutdown"), do: ["system"]
  defp topic_for_event("talk.mode"), do: ["system"]
  defp topic_for_event("heartbeat"), do: ["system"]
  defp topic_for_event("metrics"), do: ["system"]
  defp topic_for_event("log"), do: ["system"]
  defp topic_for_event("voicewake.changed"), do: ["system"]
  defp topic_for_event("custom"), do: ["system"]

  defp topic_for_event(event_name) when is_binary(event_name) do
    cond do
      String.starts_with?(event_name, "exec.approval.") -> ["exec_approvals"]
      String.starts_with?(event_name, "node.") -> ["nodes"]
      String.starts_with?(event_name, "device.") -> ["nodes"]
      true -> []
    end
  end

  defp topic_for_event(_), do: []

  defp run_topics(payload) do
    case get_event_field(payload, "runId") do
      run_id when is_binary(run_id) and run_id != "" -> ["run:#{run_id}"]
      _ -> []
    end
  end

  defp session_topics(payload) do
    case get_event_field(payload, "sessionKey") do
      session_key when is_binary(session_key) and session_key != "" -> ["session:#{session_key}"]
      _ -> []
    end
  end

  defp get_event_field(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Macro.underscore(key))
  end

  defp get_event_field(_payload, _key), do: nil

  defp dispatch_event(clients, event_name, payload, state_version) do
    payload_meta = %{event: event_name, recipients: length(clients)}

    LemonCore.Telemetry.emit(
      [:lemon, :control_plane, :event_bridge, :broadcast],
      %{count: 1, recipients: length(clients)},
      payload_meta
    )

    # FanoutSupervisor is started by the application supervision tree, so it is
    # guaranteed to be running. If it has crashed and is restarting, fall back to
    # inline dispatch.
    case Task.Supervisor.start_child(@fanout_supervisor, fn ->
           Enum.each(clients, fn {_conn_id, %{pid: pid}} ->
             send(pid, {:event, event_name, payload, state_version})
           end)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        emit_dispatch_drop(event_name, reason, length(clients))
        dispatch_inline(clients, event_name, payload, state_version)
    end
  rescue
    error ->
      emit_dispatch_drop(event_name, {:exception, error}, length(clients))
      dispatch_inline(clients, event_name, payload, state_version)
  catch
    :exit, reason ->
      emit_dispatch_drop(event_name, {:exit, reason}, length(clients))
      dispatch_inline(clients, event_name, payload, state_version)
  end

  defp dispatch_inline(clients, event_name, payload, state_version) do
    Enum.each(clients, fn {_conn_id, %{pid: pid}} ->
      send(pid, {:event, event_name, payload, state_version})
    end)
  end

  defp emit_dispatch_drop(event_name, reason, recipients) do
    LemonCore.Telemetry.emit(
      [:lemon, :control_plane, :event_bridge, :dropped],
      %{count: 1, recipients: recipients},
      %{event: event_name, reason: inspect(reason, limit: 80)}
    )
  rescue
    _ -> :ok
  end

  defp dynamic_topic?(topic) when is_binary(topic) do
    String.starts_with?(topic, "run:") || String.starts_with?(topic, "session:")
  end

  defp dynamic_topic?(_), do: false

  defp subscribe_dynamic_topic(topic, state) do
    count = Map.get(state.topic_ref_counts, topic, 0)

    if count == 0 do
      Bus.subscribe(topic)
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

  # Map bus events to WebSocket event names and payloads
  defp map_event(%LemonCore.Event{type: type, payload: payload, meta: meta}) do
    map_event_type(type, payload, meta)
  end

  defp map_event(%{type: type, payload: payload} = event) do
    meta = event[:meta] || %{}
    map_event_type(type, payload, meta)
  end

  defp map_event(_), do: nil

  # Run events
  defp map_event_type(:run_started, payload, meta) do
    {"agent",
     %{
       "type" => "started",
       "runId" => payload[:run_id] || meta[:run_id],
       "sessionKey" => payload[:session_key] || meta[:session_key],
       "engine" => payload[:engine],
       "parentRunId" => payload[:parent_run_id] || meta[:parent_run_id]
     }}
  end

  defp map_event_type(:run_completed, payload, meta) do
    completed = payload[:completed] || payload

    {"agent",
     %{
       "type" => "completed",
       "runId" => meta[:run_id],
       "sessionKey" => meta[:session_key],
       "ok" => get_field(completed, :ok),
       "answer" => truncate(get_field(completed, :answer), 500),
       "durationMs" => payload[:duration_ms]
     }}
  end

  defp map_event_type(:delta, payload, meta) do
    {"chat",
     %{
       "type" => "delta",
       "runId" => get_field(payload, :run_id) || meta[:run_id],
       "sessionKey" => meta[:session_key],
       "seq" => get_field(payload, :seq),
       "text" => get_field(payload, :text)
     }}
  end

  # Engine action events (tool_use)
  defp map_event_type(:engine_action, payload, meta) do
    action = get_field(payload, :action) || payload

    {"agent",
     %{
       "type" => "tool_use",
       "runId" => get_field(meta, :run_id),
       "sessionKey" => get_field(meta, :session_key),
       "action" => %{
         "id" => get_field(action, :id),
         "kind" => get_field(action, :kind),
         "title" => get_field(action, :title),
         "detail" => get_field(action, :detail)
       },
       "phase" => get_field(payload, :phase),
       "ok" => get_field(payload, :ok),
       "message" => get_field(payload, :message)
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

  defp map_event_type(type, payload, meta)
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
       "sessionKey" => get_field(meta, :session_key) || get_field(payload, :session_key),
       "goalId" => get_field(payload, :goal_id),
       "agentId" => get_field(payload, :agent_id),
       "status" => get_field(payload, :status),
       "objectiveBytes" => get_field(payload, :objective_bytes),
       "continuationCount" => get_field(payload, :continuation_count),
       "lastRunId" => get_field(payload, :last_run_id),
       "loopStatus" => get_field(payload, :loop_status),
       "loopVerdict" => get_field(payload, :loop_verdict)
     }}
  end

  # Approval events
  defp map_event_type(:approval_requested, payload, _meta) do
    pending = get_field(payload, :pending) || payload

    {"exec.approval.requested",
     %{
       "approvalId" => get_field(pending, :id) || get_field(payload, :approval_id),
       "runId" => get_field(pending, :run_id),
       "sessionKey" => get_field(pending, :session_key),
       "agentId" => get_field(pending, :agent_id),
       "tool" => get_field(pending, :tool),
       "action" => stringify_keys(get_field(pending, :action) || %{}),
       "rationale" => get_field(pending, :rationale),
       "requestedAtMs" => get_field(pending, :requested_at_ms),
       "expiresAtMs" => get_field(pending, :expires_at_ms)
     }}
  end

  defp map_event_type(:approval_resolved, payload, meta) do
    pending = get_field(payload, :pending) || %{}

    {"exec.approval.resolved",
     %{
       "approvalId" => get_field(payload, :approval_id),
       "decision" => to_string(get_field(payload, :decision) || :resolved),
       "runId" => get_field(pending, :run_id) || get_field(meta, :run_id),
       "sessionKey" => get_field(pending, :session_key) || get_field(meta, :session_key),
       "agentId" => get_field(pending, :agent_id),
       "tool" => get_field(pending, :tool)
     }}
  end

  # Cron events
  defp map_event_type(:cron_run_started, payload, _meta) do
    run = payload[:run] || payload
    job = payload[:job] || %{}

    {"cron",
     %{
       "type" => "started",
       "runId" => run[:run_id] || payload[:router_run_id] || run[:id],
       "cronRunId" => run[:id] || payload[:cron_run_id],
       "jobId" => run[:job_id],
       "jobName" => job[:name] || payload[:job_name],
       "agentId" => payload[:agent_id],
       "sessionKey" => payload[:session_key],
       "triggeredBy" => to_string(payload[:triggered_by] || run[:triggered_by] || :schedule),
       "startedAtMs" => run[:started_at_ms]
     }}
  end

  defp map_event_type(:cron_run_completed, payload, _meta) do
    run = payload[:run] || payload

    {"cron",
     %{
       "type" => "completed",
       "runId" => run[:run_id] || payload[:router_run_id] || run[:id],
       "cronRunId" => run[:id] || payload[:cron_run_id],
       "jobId" => run[:job_id],
       "status" => to_string(run[:status]),
       "suppressed" => run[:suppressed] || false,
       "agentId" => payload[:agent_id],
       "sessionKey" => payload[:session_key],
       "durationMs" => payload[:duration_ms] || run[:duration_ms],
       "error" => payload[:error] || run[:error]
     }}
  end

  defp map_event_type(:cron_lifecycle_action, payload, _meta) do
    audit = payload[:audit] || payload

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

  defp map_event_type(:cron_job_created, payload, _meta) do
    map_cron_job_event("created", payload)
  end

  defp map_event_type(:cron_job_updated, payload, _meta) do
    map_cron_job_event("updated", payload)
  end

  defp map_event_type(:cron_job_deleted, payload, _meta) do
    {"cron.job",
     %{
       "type" => "deleted",
       "jobId" => payload[:job_id],
       "name" => payload[:name]
     }}
  end

  # Tick events - handle both :tick and :cron_tick
  defp map_event_type(:tick, payload, _meta) do
    timestamp = extract_timestamp(payload)
    {"tick", %{"timestampMs" => timestamp}}
  end

  defp map_event_type(:cron_tick, payload, _meta) do
    timestamp = extract_timestamp(payload)
    {"tick", %{"timestampMs" => timestamp}}
  end

  # Presence events
  defp map_event_type(:presence_changed, payload, _meta) do
    {"presence",
     %{
       "connections" => payload[:connections] || [],
       "count" => payload[:count] || 0
     }}
  end

  # Talk mode events
  defp map_event_type(:talk_mode_changed, payload, _meta) do
    {"talk.mode",
     %{
       "sessionKey" => payload[:session_key],
       "mode" => to_string(payload[:mode])
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

  defp map_event_type(:heartbeat_alert, payload, _meta) do
    {"heartbeat",
     %{
       "agentId" => payload[:agent_id],
       "status" => "alert",
       "response" => payload[:response],
       "timestampMs" => payload[:timestamp_ms] || System.system_time(:millisecond)
     }}
  end

  defp map_event_type(:heartbeat_suppressed, payload, _meta) do
    {"heartbeat",
     %{
       "agentId" => payload[:agent_id],
       "status" => "suppressed",
       "runId" => payload[:run_id],
       "jobId" => payload[:job_id],
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
       "args" => payload[:args],
       "timeoutMs" => payload[:timeout_ms]
     }}
  end

  defp map_event_type(:node_invoke_completed, payload, _meta) do
    {"node.invoke.completed",
     %{
       "invokeId" => payload[:invoke_id],
       "nodeId" => payload[:node_id],
       "ok" => payload[:ok],
       "result" => payload[:result],
       "error" => payload[:error]
     }}
  end

  # System events
  defp map_event_type(:shutdown, payload, _meta) do
    {"shutdown", payload}
  end

  defp map_event_type(:health_changed, payload, _meta) do
    {"health", payload}
  end

  # Device pairing events
  defp map_event_type(:device_pair_requested, payload, _meta) do
    {"device.pair.requested",
     %{
       "pairingId" => payload[:pairing_id],
       "deviceType" => payload[:device_type],
       "deviceName" => payload[:device_name]
     }}
  end

  defp map_event_type(:device_pair_resolved, payload, _meta) do
    {"device.pair.resolved",
     %{
       "pairingId" => payload[:pairing_id],
       "status" => to_string(payload[:status]),
       "deviceType" => payload[:device_type],
       "deviceName" => payload[:device_name]
     }}
  end

  # Voicewake events
  defp map_event_type(:voicewake_changed, payload, _meta) do
    {"voicewake.changed",
     %{
       "enabled" => payload[:enabled],
       "keyword" => payload[:keyword],
       "backend" => payload[:backend]
     }}
  end

  # Custom events (from system-event with custom_* types)
  defp map_event_type(:custom_event, payload, meta) do
    # Extract the original custom event type from meta or payload
    custom_type = meta[:original_event_type] || payload[:custom_event_type] || "custom"

    {"custom",
     add_target_fields(
       %{
         "type" => custom_type,
         "payload" => payload,
         "timestampMs" => System.system_time(:millisecond)
       },
       meta
     )}
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

  # Catch-all for unmapped events
  defp map_event_type(_, _, _), do: nil

  # Helper to extract timestamp from various payload formats
  defp extract_timestamp(%{timestamp_ms: ts}), do: ts
  defp extract_timestamp(ts) when is_integer(ts), do: ts
  defp extract_timestamp(_), do: System.system_time(:millisecond)

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

  defp map_cron_job_event(type, payload) do
    job = payload[:job] || %{}

    {"cron.job",
     %{
       "type" => type,
       "jobId" => job[:id] || payload[:job_id],
       "name" => job[:name],
       "schedule" => job[:schedule],
       "enabled" => job[:enabled],
       "agentId" => job[:agent_id],
       "sessionKey" => job[:session_key],
       "nextRunAtMs" => job[:next_run_at_ms]
     }}
  end

  defp normalize_atom_or_binary(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_atom_or_binary(value) when is_binary(value), do: value
  defp normalize_atom_or_binary(value), do: value
end
