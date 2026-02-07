defmodule LemonControlPlane.EventBridge do
  @moduledoc """
  Bridges events from LemonCore.Bus to WebSocket clients.

  This GenServer subscribes to relevant bus topics and forwards events
  to connected WebSocket clients as event frames.

  ## Topics Subscribed

  - `run:*` - Run lifecycle events (agent, chat events)
  - `exec_approvals` - Approval request/resolution events
  - `cron` - Cron job events
  - `system` - System events (shutdown, health, tick, talk.mode)
  - `nodes` - Node pairing events
  - `presence` - Presence events

  ## Event Mapping

  Bus events are mapped to OpenClaw-compatible event names:

  | Bus Event                | WS Event                  |
  |--------------------------|---------------------------|
  | :run_started             | agent                     |
  | :run_completed           | agent                     |
  | :delta                   | chat                      |
  | :approval_requested      | exec.approval.requested   |
  | :approval_resolved       | exec.approval.resolved    |
  | :cron_run_started        | cron                      |
  | :cron_run_completed      | cron                      |
  | :cron_tick               | tick                      |
  | :tick                    | tick                      |
  | :presence_changed        | presence                  |
  | :talk_mode_changed       | talk.mode                 |
  | :heartbeat               | heartbeat                 |
  | :heartbeat_alert         | heartbeat                 |
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
  """

  use GenServer

  require Logger

  alias LemonCore.Bus
  alias LemonControlPlane.Presence

  @bus_topics [
    "exec_approvals",
    "cron",
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
    GenServer.cast(__MODULE__, {:subscribe_run, run_id})
  end

  @doc """
  Unsubscribe from run events.
  """
  def unsubscribe_run(run_id) do
    GenServer.cast(__MODULE__, {:unsubscribe_run, run_id})
  end

  @impl true
  def init(_opts) do
    # Subscribe to static topics
    Enum.each(@bus_topics, &Bus.subscribe/1)

    # Initialize state version counters
    state_versions = Map.new(@state_version_keys, fn key -> {key, 0} end)

    {:ok, %{
      run_subscriptions: MapSet.new(),
      state_versions: state_versions
    }}
  end

  @impl true
  def handle_cast({:subscribe_run, run_id}, state) do
    Bus.subscribe("run:#{run_id}")
    {:noreply, %{state | run_subscriptions: MapSet.put(state.run_subscriptions, run_id)}}
  end

  def handle_cast({:unsubscribe_run, run_id}, state) do
    Bus.unsubscribe("run:#{run_id}")
    {:noreply, %{state | run_subscriptions: MapSet.delete(state.run_subscriptions, run_id)}}
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
  defp state_version_key_for(_), do: nil

  # Broadcast an event to all connected clients
  defp broadcast_event(event, state_version) do
    case map_event(event) do
      nil ->
        :ok

      {event_name, payload} ->
        # Get all connected clients from presence
        clients = get_connected_clients()

        Enum.each(clients, fn {_conn_id, %{pid: pid}} ->
          send(pid, {:event, event_name, payload, state_version})
        end)
    end
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
    {"agent", %{
      "type" => "started",
      "runId" => payload[:run_id] || meta[:run_id],
      "sessionKey" => payload[:session_key] || meta[:session_key],
      "engine" => payload[:engine]
    }}
  end

  defp map_event_type(:run_completed, payload, meta) do
    completed = payload[:completed] || payload
    {"agent", %{
      "type" => "completed",
      "runId" => meta[:run_id],
      "sessionKey" => meta[:session_key],
      "ok" => get_field(completed, :ok),
      "answer" => truncate(get_field(completed, :answer), 500),
      "durationMs" => payload[:duration_ms]
    }}
  end

  defp map_event_type(:delta, payload, meta) do
    {"chat", %{
      "type" => "delta",
      "runId" => get_field(payload, :run_id) || meta[:run_id],
      "sessionKey" => meta[:session_key],
      "seq" => get_field(payload, :seq),
      "text" => get_field(payload, :text)
    }}
  end

  # Approval events
  defp map_event_type(:approval_requested, payload, _meta) do
    pending = payload[:pending] || payload
    {"exec.approval.requested", %{
      "approvalId" => pending[:id] || payload[:approval_id],
      "runId" => pending[:run_id],
      "sessionKey" => pending[:session_key],
      "agentId" => pending[:agent_id],
      "tool" => pending[:tool],
      "rationale" => pending[:rationale],
      "expiresAtMs" => pending[:expires_at_ms]
    }}
  end

  defp map_event_type(:approval_resolved, payload, _meta) do
    {"exec.approval.resolved", %{
      "approvalId" => payload[:approval_id],
      "decision" => to_string(payload[:decision])
    }}
  end

  # Cron events
  defp map_event_type(:cron_run_started, payload, _meta) do
    run = payload[:run] || payload
    job = payload[:job] || %{}
    {"cron", %{
      "type" => "started",
      "runId" => run[:id],
      "jobId" => run[:job_id],
      "jobName" => job[:name] || payload[:job_name]
    }}
  end

  defp map_event_type(:cron_run_completed, payload, _meta) do
    run = payload[:run] || payload
    {"cron", %{
      "type" => "completed",
      "runId" => run[:id],
      "jobId" => run[:job_id],
      "status" => to_string(run[:status]),
      "suppressed" => run[:suppressed] || false
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
    {"presence", %{
      "connections" => payload[:connections] || [],
      "count" => payload[:count] || 0
    }}
  end

  # Talk mode events
  defp map_event_type(:talk_mode_changed, payload, _meta) do
    {"talk.mode", %{
      "sessionKey" => payload[:session_key],
      "mode" => to_string(payload[:mode])
    }}
  end

  # Heartbeat events
  defp map_event_type(:heartbeat, payload, _meta) do
    {"heartbeat", %{
      "agentId" => payload[:agent_id],
      "status" => to_string(payload[:status] || :ok),
      "timestampMs" => payload[:timestamp_ms] || System.system_time(:millisecond)
    }}
  end

  defp map_event_type(:heartbeat_alert, payload, _meta) do
    {"heartbeat", %{
      "agentId" => payload[:agent_id],
      "status" => "alert",
      "response" => payload[:response],
      "timestampMs" => payload[:timestamp_ms] || System.system_time(:millisecond)
    }}
  end

  # Node events
  defp map_event_type(:node_pair_requested, payload, _meta) do
    {"node.pair.requested", %{
      "pairingId" => payload[:pairing_id],
      "code" => payload[:code],
      "nodeType" => payload[:node_type],
      "nodeName" => payload[:node_name],
      "expiresAtMs" => payload[:expires_at_ms]
    }}
  end

  defp map_event_type(:node_pair_resolved, payload, _meta) do
    {"node.pair.resolved", %{
      "pairingId" => payload[:pairing_id],
      "nodeId" => payload[:node_id],
      "approved" => payload[:approved] || false,
      "rejected" => payload[:rejected] || false
    }}
  end

  defp map_event_type(:node_invoke_request, payload, _meta) do
    {"node.invoke.request", %{
      "invokeId" => payload[:invoke_id],
      "nodeId" => payload[:node_id],
      "method" => payload[:method],
      "args" => payload[:args],
      "timeoutMs" => payload[:timeout_ms]
    }}
  end

  defp map_event_type(:node_invoke_completed, payload, _meta) do
    {"node.invoke.completed", %{
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
    {"device.pair.requested", %{
      "pairingId" => payload[:pairing_id],
      "deviceType" => payload[:device_type],
      "deviceName" => payload[:device_name]
    }}
  end

  defp map_event_type(:device_pair_resolved, payload, _meta) do
    {"device.pair.resolved", %{
      "pairingId" => payload[:pairing_id],
      "status" => to_string(payload[:status]),
      "deviceType" => payload[:device_type],
      "deviceName" => payload[:device_name]
    }}
  end

  # Voicewake events
  defp map_event_type(:voicewake_changed, payload, _meta) do
    {"voicewake.changed", %{
      "enabled" => payload[:enabled],
      "keyword" => payload[:keyword],
      "backend" => payload[:backend]
    }}
  end

  # Custom events (from system-event with custom_* types)
  defp map_event_type(:custom_event, payload, meta) do
    # Extract the original custom event type from meta or payload
    custom_type = meta[:original_event_type] || payload[:custom_event_type] || "custom"

    {"custom", %{
      "type" => custom_type,
      "payload" => payload,
      "timestampMs" => System.system_time(:millisecond)
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
    Map.get(data, key)
  end

  defp get_field(_, _), do: nil
end
