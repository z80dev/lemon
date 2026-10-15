defmodule LemonControlPlane.WS.Connection do
  @moduledoc """
  WebSocket connection handler for the control plane.

  Implements the Lemon control-plane WebSocket protocol with:

  - Handshake via `connect` method followed by `hello-ok` frame
  - Request/response frame handling
  - Event broadcasting and targeted execution-node delivery
  - Connection lifecycle management

  ## Protocol Flow

  1. Client connects via WebSocket
  2. Client sends `connect` request with auth params
  3. Server responds with `hello-ok` frame
  4. Normal request/response communication begins
  5. Server may push `event` frames at any time
  """

  @behaviour WebSock

  require Logger

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Methods.{NodeInvokeResult, Registry}
  alias LemonControlPlane.NodeStore
  alias LemonControlPlane.Protocol.{Errors, Frames}
  alias LemonCore.Bus.Delivery

  @heartbeat_interval_ms 25_000

  defstruct [
    :conn_id,
    :auth,
    :connected,
    :event_seq,
    :local?,
    :state_version,
    :delivery,
    :heartbeat_timer_ref,
    resync_required: false
  ]

  @type t :: %__MODULE__{
          conn_id: String.t(),
          auth: Authorize.auth_context() | nil,
          connected: boolean(),
          event_seq: non_neg_integer(),
          local?: boolean(),
          state_version: map(),
          delivery: Delivery.t() | nil,
          resync_required: boolean(),
          heartbeat_timer_ref: reference() | nil
        }

  ## WebSock Callbacks

  @impl WebSock
  def init(opts) do
    conn_id = LemonCore.Id.uuid()

    local? =
      opts |> Keyword.get(:peer) |> local_peer?() and
        Application.get_env(
          :lemon_control_plane,
          :allow_unauthenticated_loopback_operator,
          false
        ) == true

    state = %__MODULE__{
      conn_id: conn_id,
      auth: nil,
      connected: false,
      event_seq: 0,
      local?: local?,
      state_version: %{},
      delivery: Delivery.new(self())
    }

    Logger.debug("WebSocket connection initialized: #{conn_id}")

    {:ok, state}
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    max_payload = LemonControlPlane.max_payload()

    receive_limit =
      if native_node_connection?(state),
        do: max(max_payload, LemonCore.ToolPolicy.execution_max_bytes()),
        else: max_payload

    if byte_size(text) > receive_limit do
      error = Errors.invalid_request("Payload exceeds maxPayload policy")
      {:push, {:text, Frames.encode_response("unknown", {:error, error})}, state}
    else
      parse_text_frame(text, state, max_payload)
    end
  end

  def handle_in({_data, [opcode: :binary]}, state) do
    error = Errors.invalid_request("Binary frames not supported")
    {:push, {:text, Frames.encode_response("unknown", {:error, error})}, state}
  end

  defp parse_text_frame(text, state, max_payload) do
    case parse_authenticated_frame(text, state, max_payload) do
      {:ok, frame} ->
        handle_frame(frame, state)

      {:error, {:json_decode_error, reason}} ->
        error = Errors.invalid_request("Invalid JSON: #{reason}")
        {:push, {:text, Frames.encode_response("unknown", {:error, error})}, state}

      {:error, {:invalid_frame, reason}} ->
        error = Errors.invalid_request(reason)
        {:push, {:text, Frames.encode_response("unknown", {:error, error})}, state}

      {:error, {limit, _value}}
      when limit in [:max_bytes, :max_depth, :max_items, :not_json_safe] ->
        error = Errors.invalid_request("Payload violates JSON boundary policy")
        {:push, {:text, Frames.encode_response("unknown", {:error, error})}, state}
    end
  end

  defp native_node_connection?(state),
    do: state.connected && is_map(state.auth) && state.auth[:role] == :node

  defp parse_authenticated_frame(text, state, max_payload) do
    if native_node_connection?(state) do
      case Jason.decode(text) do
        {:ok, %{"type" => "req", "id" => id, "method" => method} = decoded}
        when is_binary(id) and
               method in ["node.native.followup", "node.native.lineage.floor"] ->
          with {:ok, _} <-
                 LemonCore.JSONPayload.validate(
                   decoded,
                   LemonCore.ToolPolicy.execution_json_opts()
                 ) do
            {:ok, %{type: :req, id: id, method: method, params: Map.get(decoded, "params")}}
          end

        _ ->
          Frames.parse(text, max_payload: max_payload)
      end
    else
      Frames.parse(text, max_payload: max_payload)
    end
  end

  @impl WebSock
  def handle_info({:stream_resync, :overflow}, state) do
    send(self(), :stream_overflow_disconnect)
    state = %{state | resync_required: true}
    push_event("stream.resync", %{"reason" => "overflow"}, increment_event_seq(state))
  end

  def handle_info(:stream_overflow_disconnect, state), do: {:stop, :normal, state}

  def handle_info({:event, _, _, _}, %{resync_required: true} = state), do: {:ok, state}
  def handle_info({:event, _, _}, %{resync_required: true} = state), do: {:ok, state}

  def handle_info({:node_event, event_name, payload}, state) do
    push_event(event_name, payload, increment_event_seq(state))
  end

  def handle_info({:lemon_node_result, invoke_id, result}, state) do
    :ok = NodeInvokeResult.record_registry_result(invoke_id, result)
    {:ok, state}
  end

  def handle_info({:event, event_name, payload}, state) do
    push_event(event_name, payload, increment_event_seq(state))
  end

  def handle_info({:event, event_name, payload, new_state_version}, state)
      when is_map(new_state_version) do
    state = increment_event_seq(state)
    state = %{state | state_version: Map.merge(state.state_version, new_state_version)}
    push_event(event_name, payload, state)
  end

  def handle_info({:push_frame, frame}, state) when is_binary(frame) do
    {:push, {:text, frame}, state}
  end

  def handle_info({:method_result, id, result}, state) when is_binary(id) do
    {:push, {:text, encode_response(id, result)}, state}
  end

  def handle_info({:lifecycle_after_reply, ref}, state) do
    LemonControlPlane.Lifecycle.after_reply(ref)
    {:ok, state}
  end

  def handle_info({:node_session_revoked, node_id, generation}, state) do
    Logger.info(
      "Closing superseded node session #{state.conn_id} for #{node_id} before generation #{generation}"
    )

    {:stop, :normal, state}
  end

  def handle_info(:heartbeat, %{connected: true} = state) do
    timer_ref = Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
    {:push, {:ping, ""}, %{state | heartbeat_timer_ref: timer_ref}}
  end

  def handle_info(:heartbeat, state), do: {:ok, state}

  def handle_info(msg, state) do
    Logger.debug("Unhandled message in WS connection: #{inspect(msg)}")
    {:ok, state}
  end

  @impl WebSock
  def terminate(reason, state) do
    Logger.debug("WebSocket connection terminated: #{state.conn_id}, reason: #{inspect(reason)}")

    if state.delivery, do: Delivery.close(state.delivery)

    if is_reference(state.heartbeat_timer_ref),
      do: Process.cancel_timer(state.heartbeat_timer_ref)

    # Unregister from presence
    if state.connected do
      unregister_presence(state)
      unregister_node_connection(state)
    end

    :ok
  end

  # Encoding is a wire boundary: a malformed publisher must not disconnect the
  # socket or prevent later completion events. Do not log payloads, event names,
  # exception messages or arbitrary failure terms here.
  defp push_event(event_name, payload, state) do
    frame = Frames.encode_event(event_name, payload, state.event_seq, state.state_version)
    {:push, {:text, frame}, state}
  rescue
    error ->
      drop_event(encoding_failure_class(error), state)
  catch
    :throw, _ -> drop_event("encoding_throw", state)
    :exit, _ -> drop_event("encoding_exit", state)
  end

  defp drop_event(classification, state) do
    Logger.warning("Dropping WS event frame: " <> classification)
    {:ok, state}
  end

  defp encode_response(id, result) do
    Frames.encode_response(id, result)
  rescue
    error -> response_encoding_failed(id, encoding_failure_class(error))
  catch
    :throw, _ -> response_encoding_failed(id, "encoding_throw")
    :exit, _ -> response_encoding_failed(id, "encoding_exit")
  end

  defp response_encoding_failed(id, classification) do
    Logger.warning("Replacing invalid WS response frame: " <> classification)

    Frames.encode_response(
      id,
      {:error,
       Errors.internal_error("Response could not be encoded; reconcile the operation outcome", %{
         "code" => "RESPONSE_ENCODING_FAILED",
         "retrySafe" => false
       })}
    )
  end

  defp encoding_failure_class(%Protocol.UndefinedError{}), do: "unsupported_json_type"
  defp encoding_failure_class(%Jason.EncodeError{}), do: "invalid_json_value"
  defp encoding_failure_class(%ArgumentError{}), do: "invalid_encoding_argument"
  defp encoding_failure_class(_), do: "encoding_exception"

  ## Frame Handling

  defp handle_frame(%{type: :req, id: id, method: "connect", params: params}, state) do
    if state.connected do
      error = Errors.already_connected()
      {:push, {:text, Frames.encode_response(id, {:error, error})}, state}
    else
      handle_connect(id, params, state)
    end
  end

  defp handle_frame(%{type: :req, id: id, method: method, params: params}, state) do
    if not state.connected do
      error = Errors.handshake_required()
      {:push, {:text, Frames.encode_response(id, {:error, error})}, state}
    else
      handle_method(id, method, params, state)
    end
  end

  ## Connect Handshake

  defp handle_connect(id, params, state) do
    case Authorize.from_params(params || %{}, local?: state.local?) do
      {:ok, auth} ->
        case register_node_connection(auth, params || %{}) do
          :ok ->
            finish_connect(auth, state)

          {:error, error} ->
            {:push, {:text, Frames.encode_response(id, {:error, error})}, state}
        end

      {:error, {:unauthorized, message}} ->
        message =
          if Map.get(params || %{}, "role") in [nil, "operator"] do
            message <>
              ". Set connect.auth.token from LEMON_CONTROL_PLANE_OPERATOR_TOKEN or the launcher's ~/.lemon/run/control-plane-<port>.token file."
          else
            message
          end

        error = Errors.unauthorized(message)
        {:push, {:text, Frames.encode_response(id, {:error, error})}, state}
    end
  end

  defp finish_connect(auth, state) do
    timer_ref = Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
    state = %{state | auth: auth, connected: true, heartbeat_timer_ref: timer_ref}

    # Register with presence
    register_presence(state)

    # Build hello-ok response - connect uses a dedicated hello-ok handshake frame.
    hello_ok =
      Frames.encode_hello_ok(%{
        conn_id: state.conn_id,
        methods: Registry.list_methods(),
        events: Frames.supported_events(),
        snapshot: build_snapshot(state),
        auth: build_auth_response(auth),
        max_payload: LemonControlPlane.max_payload()
      })

    Logger.info("WebSocket connection established: #{state.conn_id}, role: #{auth.role}")

    # Only send hello-ok, NOT an additional res frame.
    {:push, {:text, hello_ok}, state}
  end

  ## Method Dispatch

  defp handle_method(id, method, params, state) do
    ctx = %{
      auth: state.auth,
      conn_id: state.conn_id,
      conn_pid: self()
    }

    case Registry.dispatch_mode(method) do
      :async ->
        connection_pid = self()

        {:ok, _pid} =
          Task.start(fn ->
            result = safe_async_dispatch(method, params, ctx)
            send(connection_pid, {:method_result, id, result})
          end)

        {:ok, state}

      :inline ->
        result = Registry.dispatch(method, params, ctx)
        response = encode_response(id, result)

        {:push, {:text, response}, state}
    end
  end

  defp safe_async_dispatch(method, params, ctx) do
    Registry.dispatch(method, params, ctx)
  catch
    kind, reason ->
      Logger.error(
        "Async WebSocket method #{method} failed: #{Exception.format_banner(kind, reason)}"
      )

      {:error, Errors.internal_error("Method execution failed")}
  end

  ## Helpers

  defp increment_event_seq(state) do
    %{state | event_seq: state.event_seq + 1}
  end

  defp build_snapshot(_state) do
    # Return initial snapshot data
    %{
      "presence" => %{},
      "health" => %{"ok" => true}
    }
  end

  defp build_auth_response(auth) do
    base = %{
      "role" => to_string(auth.role),
      "scopes" => Enum.map(auth.scopes, &to_string/1)
    }

    # Helpful for nodes: when authenticated via token, client_id is set to nodeId.
    if auth.client_id do
      Map.put(base, "clientId", auth.client_id)
    else
      base
    end
  end

  defp register_node_connection(%{role: :node} = auth, params) do
    node_id = auth.client_id
    identity = Map.get(auth, :identity)

    cond do
      not authenticated_node_identity?(identity, node_id) ->
        {:error, Errors.unauthorized("A valid node session token is required")}

      not is_binary(node_id) or node_id == "" ->
        {:error, Errors.unauthorized("Node identity is missing a node ID")}

      true ->
        case NodeStore.get_node(node_id) do
          nil ->
            {:error, Errors.unauthorized("Paired node was not found")}

          node ->
            register_durable_node(node_id, node, auth, params)
        end
    end
  end

  defp register_node_connection(_auth, _params), do: :ok

  defp register_durable_node(node_id, node, auth, params) do
    name = get_field(node, :name)

    with true <- is_binary(name) and String.trim(name) != "",
         :ok <- NodeStore.reserve_node_name(name, node_id),
         :ok <- register_live_node(node_id, name, node, auth, params) do
      case mark_node_status(node_id, node, :online) do
        :ok ->
          :ok

        {:error, reason} ->
          LemonCore.NodeRegistry.unregister(node_id, self())
          Logger.error("Failed to persist node connection: #{inspect(reason)}")
          {:error, Errors.internal_error("Failed to persist node connection")}
      end
    else
      false ->
        {:error, Errors.unauthorized("Paired node has no durable name")}

      {:error, {:name_taken, _name}} ->
        {:error, Errors.conflict("Node name is already in use")}

      {:error, :invalid_name} ->
        {:error, Errors.unauthorized("Paired node has no durable name")}

      {:error, reason} ->
        Logger.error("Failed to register node connection: #{inspect(reason)}")
        {:error, Errors.internal_error("Failed to register node connection")}
    end
  end

  defp register_live_node(node_id, name, node, auth, params) do
    generation = get_field(auth.identity || %{}, :sessionGeneration) || 0

    LemonCore.NodeRegistry.register_session(node_id, name, self(), generation, %{
      type: get_field(node, :type),
      capabilities: live_capabilities(node, params)
    })
  end

  defp live_capabilities(node, params) do
    stored = get_field(node, :capabilities)
    stored = if is_map(stored), do: stored, else: %{}

    legacy =
      Map.new(stored, fn {method, descriptor} ->
        descriptor =
          cond do
            is_map(descriptor) && method in ["coding_agent.run", :"coding_agent.run"] ->
              Map.drop(descriptor, ["nativePrivacyContext", :nativePrivacyContext])

            is_map(descriptor) && is_binary(method) && String.starts_with?(method, "memory.") ->
              Map.drop(descriptor, ["contextVersion", :contextVersion])

            is_map(descriptor) && is_atom(method) &&
                String.starts_with?(Atom.to_string(method), "memory.") ->
              Map.drop(descriptor, ["contextVersion", :contextVersion])

            true ->
              descriptor
          end

        {method, descriptor}
      end)

    case Map.get(params, :capabilities, Map.get(params, "capabilities")) do
      current when is_map(current) -> Map.merge(legacy, current)
      _ -> legacy
    end
  end

  defp unregister_node_connection(%{auth: %{role: :node, client_id: node_id}})
       when is_binary(node_id) do
    LemonCore.NodeRegistry.unregister(node_id, self())

    unless LemonCore.NodeRegistry.online?(node_id) do
      case NodeStore.get_node(node_id) do
        node when is_map(node) -> mark_node_status(node_id, node, :offline)
        _ -> :ok
      end
    end
  end

  defp unregister_node_connection(_state), do: :ok

  defp mark_node_status(node_id, node, status) do
    NodeStore.put_node(
      node_id,
      Map.merge(node, %{status: status, last_seen_ms: System.system_time(:millisecond)})
    )
  end

  defp authenticated_node_identity?(identity, node_id) when is_map(identity) do
    type = Map.get(identity, "type") || Map.get(identity, :type)
    identity_node_id = Map.get(identity, "nodeId") || Map.get(identity, "node_id")
    type == "node" and identity_node_id == node_id
  end

  defp authenticated_node_identity?(_identity, _node_id), do: false

  # The HTTP router always supplies the actual socket peer. A loopback peer is
  # eligible for tokenless compatibility only when the operator explicitly
  # enables it; merely arriving from a local proxy is never sufficient by
  # default. Direct callers of Authorize.from_params/1 retain their separate
  # in-process compatibility behavior.
  defp local_peer?(nil), do: true
  defp local_peer?(peer), do: Authorize.loopback_address?(peer)

  defp get_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp register_presence(state) do
    case Process.whereis(LemonControlPlane.Presence) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        LemonControlPlane.Presence.register(state.conn_id, %{
          role: state.auth.role,
          client_id: state.auth.client_id,
          pid: self(),
          delivery: state.delivery
        })
    end
  end

  defp unregister_presence(state) do
    case Process.whereis(LemonControlPlane.Presence) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        LemonControlPlane.Presence.unregister(state.conn_id)
    end
  end
end
