defmodule LemonControlPlane.Methods.SystemEvent do
  @moduledoc """
  Handler for the system-event control plane method.

  Allows sending system-level events to the control plane.
  This method is used for:
  - Custom event injection for testing
  - External system integration
  - Event forwarding from nodes

  Only allowed event types can be emitted, which bounds the atom table.

  Types that have a typed payload in `LemonCore.Events` carry a second requirement: the
  supplied payload must coerce cleanly into that struct, or the call is rejected. This method
  can broadcast onto any `run:<id>` or `session:<key>` topic, so without that check an
  admin-scoped client could fabricate a malformed `run_completed` and every subscriber — chat
  plugins, the web UI, the ACP server, cron's completion waiters — would act on it as though
  the engine had produced it. Validating rather than banning keeps legitimate operator
  injection working: a well-formed event is indistinguishable from a real one, which is the
  point, while a malformed one never reaches a subscriber.

  Types outside the registry (`shutdown`, `tick`, node and device pairing, the `custom_*`
  family) have no declared shape and keep their previous pass-through behaviour.
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
  def name, do: "system-event"

  @impl true
  def scopes, do: [:admin]

  @doc """
  Returns the list of allowed event type strings.
  """
  @spec allowed_event_types() :: [String.t()]
  def allowed_event_types, do: Map.keys(@allowed_event_types)

  @doc """
  The full mapping of allowed event type strings to their atoms.

  Exposed so callers can ask whether a given type is one of the typed platform events in
  `LemonCore.Events` — those require a payload that coerces into the declared struct.
  """
  @spec event_type_atoms() :: %{String.t() => atom()}
  def event_type_atoms, do: @allowed_event_types

  @impl true
  def handle(params, ctx) do
    params = params || %{}
    event_type = params["eventType"] || params["event_type"] || params[:event_type]
    payload = params["payload"] || params[:payload] || %{}
    target = params["target"] || params[:target]

    cond do
      is_nil(event_type) or event_type == "" ->
        {:error, {:invalid_request, "eventType is required", nil}}

      not is_map(payload) ->
        {:error, {:invalid_request, "payload must be an object", nil}}

      true ->
        case validate_and_convert_event_type(event_type) do
          {:ok, atom_type, is_custom} ->
            case validate_target(target) do
              {:ok, topic} ->
                emit_event(event_type, atom_type, payload, topic, ctx, is_custom)

              {:error, reason} ->
                {:error, {:invalid_request, reason, nil}}
            end

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
        {:error,
         "Invalid event type '#{event_type}'. Allowed types: #{Enum.join(allowed_event_types(), ", ")}"}
    end
  end

  defp validate_and_convert_event_type(_), do: {:error, "eventType must be a string"}

  defp validate_target(nil), do: {:ok, "system"}

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

  defp emit_event(original_type, atom_type, payload, topic, ctx, is_custom) do
    with {:ok, final_payload} <- build_payload(atom_type, payload, original_type, is_custom) do
      broadcast_event(original_type, atom_type, final_payload, topic, ctx)
    end
  end

  # A registered type must produce its declared struct or the injection is refused; an
  # unregistered one keeps its free-form map.
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
             {:invalid_request, "payload is not a valid '#{original_type}' event: #{reason}", nil}}
        end

      true ->
        {:ok, payload}
    end
  end

  defp broadcast_event(original_type, atom_type, final_payload, topic, ctx) do
    event = %LemonCore.Event{
      type: atom_type,
      ts_ms: System.system_time(:millisecond),
      payload: final_payload,
      meta: %{
        origin: :system_event,
        conn_id: ctx[:conn_id],
        target: topic,
        original_event_type: original_type
      }
    }

    Bus.broadcast(topic, event)

    {:ok,
     %{
       "success" => true,
       "eventType" => original_type,
       "topic" => topic,
       "timestamp" => event.ts_ms,
       "summary" => summary(original_type, topic, event)
     }}
  end

  # Struct payloads carry a `__struct__` key that is not a field; counting it would report
  # one more key than the event actually has.
  defp payload_key_count(%_{} = payload), do: payload |> Map.from_struct() |> map_size()
  defp payload_key_count(payload) when is_map(payload), do: map_size(payload)
  defp payload_key_count(_payload), do: 0

  defp summary(original_type, topic, event) do
    %{
      "eventType" => original_type,
      "topic" => topic,
      "targetKind" => target_kind(topic),
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
  defp target_kind(topic), do: topic
end
