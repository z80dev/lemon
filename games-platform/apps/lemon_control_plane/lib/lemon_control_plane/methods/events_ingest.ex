defmodule LemonControlPlane.Methods.EventsIngest do
  @moduledoc """
  Ingest events into the system.

  Allows external systems or nodes to emit events into the Lemon event bus.
  Events are validated, transformed, and broadcast to subscribed clients.

  ## Parameters

    - `eventType` - Type of event (required)
    - `payload` - Event payload data (required)
    - `target` - Target topic for the event (optional, defaults to "system")

  ## Allowed Event Types

    - `"custom"` - Custom event
    - `"heartbeat"` - Heartbeat/ping event
    - `"metrics"` - Metrics data
    - `"log"` - Log entry
    - Any type starting with `"custom_"` - Custom prefixed events

  ## Example

      {
        "method": "events.ingest",
        "params": {
          "eventType": "custom",
          "payload": {"message": "Hello from external system"},
          "target": "system"
        }
      }
  """

  @behaviour LemonControlPlane.Method

  alias LemonCore.Bus
  alias LemonControlPlane.Protocol.Errors

  # Allowed event types to prevent atom exhaustion
  @allowed_event_types %{
    "custom" => :custom_event,
    "heartbeat" => :heartbeat,
    "metrics" => :metrics,
    "log" => :log
  }

  @impl true
  def name, do: "events.ingest"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    event_type = params["eventType"] || params["event_type"]
    payload = params["payload"] || %{}
    target = params["target"] || "system"

    if is_nil(event_type) or event_type == "" do
      {:error, Errors.invalid_request("eventType is required")}
    else
      case validate_and_convert_event_type(event_type) do
        {:ok, atom_type, is_custom} ->
          ingest_event(event_type, atom_type, payload, target, is_custom)

        {:error, reason} ->
          {:error, Errors.invalid_request(reason)}
      end
    end
  end

  defp validate_and_convert_event_type(event_type) when is_binary(event_type) do
    cond do
      Map.has_key?(@allowed_event_types, event_type) ->
        {:ok, Map.get(@allowed_event_types, event_type), false}

      String.starts_with?(event_type, "custom_") ->
        {:ok, :custom_event, true}

      true ->
          {:error,
         "Invalid event type '#{event_type}'. Allowed types: #{Enum.join(Map.keys(@allowed_event_types), ", ")}, or custom_*"}
    end
  end

  defp ingest_event(original_type, atom_type, payload, target, is_custom) do
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
        origin: :events_ingest,
        original_event_type: original_type
      }
    }

    Bus.broadcast(target, event)

    {:ok, %{
      "ingested" => true,
      "eventType" => original_type,
      "target" => target,
      "timestampMs" => event.ts_ms
    }}
  end
end
