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

  @allowed_targets [
    "system",
    "channels",
    "cron",
    "exec_approvals",
    "goals",
    "nodes",
    "presence"
  ]

  @impl true
  def name, do: "events.ingest"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    event_type = params["eventType"] || params["event_type"] || params[:event_type]
    payload = params["payload"] || params[:payload] || %{}
    target = params["target"] || params[:target] || "system"

    cond do
      is_nil(event_type) or event_type == "" ->
        {:error, Errors.invalid_request("eventType is required")}

      not is_map(payload) ->
        {:error, Errors.invalid_request("payload must be an object")}

      true ->
        case validate_and_convert_event_type(event_type) do
          {:ok, atom_type, is_custom} ->
            case validate_target(target) do
              {:ok, target} ->
                ingest_event(event_type, atom_type, payload, target, is_custom)

              {:error, reason} ->
                {:error, Errors.invalid_request(reason)}
            end

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

  defp validate_and_convert_event_type(_), do: {:error, "eventType must be a string"}

  defp validate_target(target) when is_binary(target) do
    cond do
      target in @allowed_targets ->
        {:ok, target}

      String.starts_with?(target, "run:") and byte_size(target) > 4 ->
        {:ok, target}

      String.starts_with?(target, "session:") and byte_size(target) > 8 ->
        {:ok, target}

      true ->
        {:error,
         "Invalid target '#{target}'. Allowed targets: #{Enum.join(@allowed_targets, ", ")}, run:<id>, or session:<key>"}
    end
  end

  defp validate_target(_), do: {:error, "target must be a string"}

  defp ingest_event(original_type, atom_type, payload, target, is_custom) do
    with {:ok, final_payload} <- build_payload(atom_type, payload, original_type, is_custom) do
      broadcast_event(original_type, atom_type, final_payload, target)
    end
  end

  # This method can target any `run:<id>` or `session:<key>` topic. A type with a typed
  # payload in `LemonCore.Events` therefore has to prove its payload really is that shape
  # before it reaches a run's subscribers; anything else would let a client forge the
  # publisher's output. None of the four allowed types are registered today, so this is
  # future-proofing — it stays correct as the registry grows. Same rule as
  # `LemonControlPlane.Methods.SystemEvent`.
  defp build_payload(atom_type, payload, original_type, is_custom) do
    cond do
      is_custom ->
        {:ok, Map.put(payload, :custom_event_type, original_type)}

      LemonCore.Events.registered?(atom_type) ->
        case LemonCore.Events.cast(atom_type, payload) do
          {:ok, typed} ->
            {:ok, typed}

          {:error, reason} ->
            {:error,
             Errors.invalid_request("payload is not a valid '#{original_type}' event: #{reason}")}
        end

      true ->
        {:ok, payload}
    end
  end

  defp broadcast_event(original_type, atom_type, final_payload, target) do
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

    {:ok,
     %{
       "ingested" => true,
       "eventType" => original_type,
       "target" => target,
       "timestampMs" => event.ts_ms,
       "summary" => summary(original_type, target, event)
     }}
  end

  # Struct payloads carry a `__struct__` key that is not a field; counting it would report
  # one more key than the event actually has.
  defp payload_key_count(%_{} = payload), do: payload |> Map.from_struct() |> map_size()
  defp payload_key_count(payload) when is_map(payload), do: map_size(payload)
  defp payload_key_count(_payload), do: 0

  defp summary(original_type, target, event) do
    %{
      "eventType" => original_type,
      "target" => target,
      "targetKind" => target_kind(target),
      "timestampMs" => event.ts_ms,
      "payloadKeyCount" => payload_key_count(event.payload),
      "custom" => String.starts_with?(original_type, "custom_"),
      "cleanup" => %{
        "includesPayload" => false,
        "includesMessageBodies" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp target_kind("run:" <> _), do: "run"
  defp target_kind("session:" <> _), do: "session"
  defp target_kind(target), do: target
end
