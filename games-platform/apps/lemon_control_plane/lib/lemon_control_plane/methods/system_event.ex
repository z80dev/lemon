defmodule LemonControlPlane.Methods.SystemEvent do
  @moduledoc """
  Handler for the system-event control plane method.

  Allows sending system-level events to the control plane.
  This method is used for:
  - Custom event injection for testing
  - External system integration
  - Event forwarding from nodes

  Note: Only allowed event types can be emitted to prevent atom table exhaustion.
  """

  @behaviour LemonControlPlane.Method

  alias LemonCore.Bus

  # Allowed event types to prevent atom exhaustion.
  # These are the only event types that can be emitted via system-event.
  @allowed_event_types %{
    "shutdown" => :shutdown,
    "health_changed" => :health_changed,
    "tick" => :tick,
    "presence_changed" => :presence_changed,
    "talk_mode_changed" => :talk_mode_changed,
    "heartbeat" => :heartbeat,
    "heartbeat_alert" => :heartbeat_alert,
    "run_started" => :run_started,
    "run_completed" => :run_completed,
    "delta" => :delta,
    "approval_requested" => :approval_requested,
    "approval_resolved" => :approval_resolved,
    "cron_run_started" => :cron_run_started,
    "cron_run_completed" => :cron_run_completed,
    "cron_tick" => :cron_tick,
    "node_pair_requested" => :node_pair_requested,
    "node_pair_resolved" => :node_pair_resolved,
    "node_invoke_request" => :node_invoke_request,
    "node_invoke_completed" => :node_invoke_completed,
    "device_pair_requested" => :device_pair_requested,
    "device_pair_resolved" => :device_pair_resolved,
    "voicewake_changed" => :voicewake_changed,
    # Allow custom events with prefix "custom_" - these use a safe atom
    "custom" => :custom_event
  }

  @impl true
  def name, do: "system-event"

  @impl true
  def scopes, do: [:admin]

  @doc """
  Returns the list of allowed event type strings.
  """
  @spec allowed_event_types() :: [String.t()]
  def allowed_event_types, do: Map.keys(@allowed_event_types)

  @impl true
  def handle(params, ctx) do
    event_type = params["eventType"] || params["event_type"]
    payload = params["payload"] || %{}
    target = params["target"]

    if is_nil(event_type) or event_type == "" do
      {:error, {:invalid_request, "eventType is required", nil}}
    else
      case validate_and_convert_event_type(event_type) do
        {:ok, atom_type, is_custom} ->
          emit_event(event_type, atom_type, payload, target, ctx, is_custom)

        {:error, reason} ->
          {:error, {:invalid_request, reason, nil}}
      end
    end
  end

  # Validate event type and convert to atom safely
  defp validate_and_convert_event_type(event_type) when is_binary(event_type) do
    cond do
      # Direct match in allowed types
      Map.has_key?(@allowed_event_types, event_type) ->
        {:ok, Map.get(@allowed_event_types, event_type), false}

      # Custom event with prefix
      String.starts_with?(event_type, "custom_") ->
        # Use the generic :custom_event atom but preserve the type in payload
        {:ok, :custom_event, true}

      true ->
        {:error, "Invalid event type '#{event_type}'. Allowed types: #{Enum.join(allowed_event_types(), ", ")}"}
    end
  end

  defp emit_event(original_type, atom_type, payload, target, ctx, is_custom) do
    # For custom events, include the original type in the payload
    final_payload =
      if is_custom do
        Map.put(payload, :custom_event_type, original_type)
      else
        payload
      end

    event = %LemonCore.Event{
      type: atom_type,
      ts_ms: System.system_time(:millisecond),
      payload: final_payload,
      meta: %{
        origin: :system_event,
        conn_id: ctx[:conn_id],
        target: target,
        original_event_type: original_type
      }
    }

    # Determine topic based on target
    topic = determine_topic(target, original_type)

    # Broadcast the event
    Bus.broadcast(topic, event)

    {:ok, %{
      "success" => true,
      "eventType" => original_type,
      "topic" => topic,
      "timestamp" => event.ts_ms
    }}
  end

  defp determine_topic(nil, _event_type), do: "system"
  defp determine_topic("system", _event_type), do: "system"
  defp determine_topic("run:" <> run_id, _event_type), do: "run:#{run_id}"
  defp determine_topic("session:" <> session_key, _event_type), do: "session:#{session_key}"
  defp determine_topic("channels", _event_type), do: "channels"
  defp determine_topic("nodes", _event_type), do: "nodes"
  defp determine_topic("cron", _event_type), do: "cron"
  defp determine_topic(custom, _event_type), do: custom
end
