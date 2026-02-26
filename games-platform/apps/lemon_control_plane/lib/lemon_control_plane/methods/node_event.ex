defmodule LemonControlPlane.Methods.NodeEvent do
  @moduledoc """
  Handler for the node.event control plane method.

  Called by nodes to emit events.
  Role: node

  Note: Only allowed event types can be emitted to prevent atom table exhaustion.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  # Allowed node event types to prevent atom exhaustion.
  # Maps string event types to the corresponding atom.
  @allowed_event_types %{
    "status" => :node_status,
    "heartbeat" => :node_heartbeat,
    "error" => :node_error,
    "connected" => :node_connected,
    "disconnected" => :node_disconnected,
    "invoke_completed" => :node_invoke_completed,
    "invoke_failed" => :node_invoke_failed,
    "capability_changed" => :node_capability_changed,
    "metrics" => :node_metrics,
    "log" => :node_log,
    # Generic custom event for extensibility
    "custom" => :node_custom
  }

  @impl true
  def name, do: "node.event"

  @impl true
  def scopes, do: []  # Node role required

  @doc """
  Returns the list of allowed event type strings for node events.
  """
  @spec allowed_event_types() :: [String.t()]
  def allowed_event_types, do: Map.keys(@allowed_event_types)

  @impl true
  def handle(params, ctx) do
    # Verify node role - check ctx.auth.role (dispatcher passes ctx.auth in :auth key)
    auth = ctx[:auth] || ctx
    role = auth[:role] || auth.role

    if role != :node do
      {:error, Errors.forbidden("This method requires node role")}
    else
      event_type = params["eventType"] || params["event_type"] || params["type"]
      payload = params["payload"] || %{}

      if is_nil(event_type) or event_type == "" do
        {:error, Errors.invalid_request("eventType is required")}
      else
        case validate_and_convert_event_type(event_type) do
          {:ok, atom_type, is_custom} ->
            node_id = auth[:client_id] || auth.client_id
            emit_node_event(event_type, atom_type, payload, node_id, is_custom)

          {:error, reason} ->
            {:error, Errors.invalid_request(reason)}
        end
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
        {:ok, :node_custom, true}

      true ->
        {:error, "Invalid event type '#{event_type}'. Allowed types: #{Enum.join(allowed_event_types(), ", ")}"}
    end
  end

  defp emit_node_event(original_type, atom_type, payload, node_id, is_custom) do
    # For custom events, include the original type in the payload
    final_payload =
      if is_custom do
        Map.merge(payload, %{node_id: node_id, custom_event_type: original_type})
      else
        Map.merge(payload, %{node_id: node_id})
      end

    # Broadcast node event
    event = LemonCore.Event.new(
      atom_type,
      final_payload,
      %{node_id: node_id, event_type: original_type}
    )
    LemonCore.Bus.broadcast("nodes", event)

    # Update node last_seen
    if node_id do
      case LemonCore.Store.get(:nodes_registry, node_id) do
        nil -> :ok
        node ->
          # Use Map.merge instead of update syntax to handle both atom and string keys
          updated = Map.merge(node, %{last_seen_ms: System.system_time(:millisecond)})
          LemonCore.Store.put(:nodes_registry, node_id, updated)
      end
    end

    {:ok, %{
      "eventType" => original_type,
      "broadcast" => true
    }}
  end
end
