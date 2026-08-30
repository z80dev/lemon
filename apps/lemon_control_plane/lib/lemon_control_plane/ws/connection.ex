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

  alias LemonControlPlane.Protocol.{Frames, Errors}
  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Methods.{NodeInvokeResult, Registry}
  alias LemonControlPlane.NodeStore

  defstruct [
    :conn_id,
    :auth,
    :connected,
    :event_seq,
    :local?,
    :state_version,
    :subscription_mode,
    :subscriptions
  ]

  @type t :: %__MODULE__{
          conn_id: String.t(),
          auth: Authorize.auth_context() | nil,
          connected: boolean(),
          event_seq: non_neg_integer(),
          local?: boolean(),
          state_version: map(),
          subscription_mode: :all | :custom | nil,
          subscriptions: MapSet.t()
        }

  ## WebSock Callbacks

  @impl WebSock
  def init(opts) do
    conn_id = LemonCore.Id.uuid()
    local? = opts |> Keyword.get(:peer) |> local_peer?()

    state = %__MODULE__{
      conn_id: conn_id,
      auth: nil,
      connected: false,
      event_seq: 0,
      local?: local?,
      state_version: %{},
      subscription_mode: :all,
      subscriptions: MapSet.new()
    }

    Logger.debug("WebSocket connection initialized: #{conn_id}")

    {:ok, state}
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    max_payload = LemonControlPlane.max_payload()

    if byte_size(text) > max_payload do
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
    case Frames.parse(text, max_payload: max_payload) do
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

  @impl WebSock
  def handle_info({:node_event, event_name, payload}, state) do
    state = increment_event_seq(state)
    frame = Frames.encode_event(event_name, payload, state.event_seq, state.state_version)
    {:push, {:text, frame}, state}
  end

  def handle_info({:lemon_node_result, invoke_id, result}, state) do
    :ok = NodeInvokeResult.record_registry_result(invoke_id, result)
    {:ok, state}
  end

  def handle_info({:event, event_name, payload}, state) do
    if subscribed_to_event?(state, event_name, payload) do
      state = increment_event_seq(state)
      frame = Frames.encode_event(event_name, payload, state.event_seq, state.state_version)
      {:push, {:text, frame}, state}
    else
      {:ok, state}
    end
  end

  def handle_info({:event, event_name, payload, new_state_version}, state)
      when is_map(new_state_version) do
    if subscribed_to_event?(state, event_name, payload) do
      state = increment_event_seq(state)
      state = %{state | state_version: Map.merge(state.state_version, new_state_version)}
      frame = Frames.encode_event(event_name, payload, state.event_seq, state.state_version)
      {:push, {:text, frame}, state}
    else
      {:ok, state}
    end
  end

  def handle_info({:push_frame, frame}, state) when is_binary(frame) do
    {:push, {:text, frame}, state}
  end

  def handle_info({:subscribe_topics, topics}, state) do
    subscriptions =
      topics
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.reduce(state.subscriptions, &MapSet.put(&2, &1))

    state = %{state | subscription_mode: :custom, subscriptions: subscriptions}
    update_presence_subscriptions(state)
    {:ok, state}
  end

  def handle_info({:unsubscribe_topics, :all}, state) do
    state = %{state | subscription_mode: :custom, subscriptions: MapSet.new()}
    update_presence_subscriptions(state)
    {:ok, state}
  end

  def handle_info({:unsubscribe_topics, topics}, state) do
    subscriptions =
      topics
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.reduce(state.subscriptions, &MapSet.delete(&2, &1))

    state = %{state | subscription_mode: :custom, subscriptions: subscriptions}
    update_presence_subscriptions(state)
    {:ok, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Unhandled message in WS connection: #{inspect(msg)}")
    {:ok, state}
  end

  @impl WebSock
  def terminate(reason, state) do
    Logger.debug("WebSocket connection terminated: #{state.conn_id}, reason: #{inspect(reason)}")

    # Unregister from presence
    if state.connected do
      unregister_presence(state)
      unregister_node_connection(state)
    end

    :ok
  end

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
        case register_node_connection(auth) do
          :ok ->
            finish_connect(auth, state)

          {:error, error} ->
            {:push, {:text, Frames.encode_response(id, {:error, error})}, state}
        end

      {:error, {:unauthorized, _message} = error} ->
        # For auth errors, we still send a res frame with the error
        {:push, {:text, Frames.encode_response(id, {:error, error})}, state}

      {:error, _reason} ->
        error = Errors.unauthorized()
        {:push, {:text, Frames.encode_response(id, {:error, error})}, state}
    end
  end

  defp finish_connect(auth, state) do
    state = %{state | auth: auth, connected: true}

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
      conn_pid: self(),
      subscription_mode: state.subscription_mode,
      subscriptions: state.subscriptions
    }

    result = Registry.dispatch(method, params, ctx)
    response = Frames.encode_response(id, result)

    {:push, {:text, response}, state}
  end

  ## Helpers

  defp increment_event_seq(state) do
    %{state | event_seq: state.event_seq + 1}
  end

  defp subscribed_to_event?(%{subscription_mode: :all}, _event_name, _payload), do: true
  defp subscribed_to_event?(%{subscription_mode: nil}, _event_name, _payload), do: true

  defp subscribed_to_event?(state, event_name, payload) do
    subscriptions = state.subscriptions || MapSet.new()

    MapSet.member?(subscriptions, "all") ||
      event_topics(event_name, payload)
      |> Enum.any?(&MapSet.member?(subscriptions, &1))
  end

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

    # Helpful for nodes: when authenticated via token, client_id is set to nodeId/deviceId.
    if auth.client_id do
      Map.put(base, "clientId", auth.client_id)
    else
      base
    end
  end

  defp register_node_connection(%{role: :node} = auth) do
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
            register_durable_node(node_id, node)
        end
    end
  end

  defp register_node_connection(_auth), do: :ok

  defp register_durable_node(node_id, node) do
    name = get_field(node, :name)

    with true <- is_binary(name) and String.trim(name) != "",
         :ok <- NodeStore.reserve_node_name(name, node_id),
         :ok <- register_live_node(node_id, name, node) do
      case mark_node_status(node_id, node, :online) do
        :ok ->
          :ok

        {:error, reason} ->
          LemonCore.NodeRegistry.unregister(node_id, self())
          {:error, Errors.internal_error("Failed to persist node connection", reason)}
      end
    else
      false ->
        {:error, Errors.unauthorized("Paired node has no durable name")}

      {:error, {:name_taken, _name}} ->
        {:error, Errors.conflict("Node name is already in use")}

      {:error, :invalid_name} ->
        {:error, Errors.unauthorized("Paired node has no durable name")}

      {:error, reason} ->
        {:error, Errors.internal_error("Failed to register node connection", reason)}
    end
  end

  defp register_live_node(node_id, name, node) do
    LemonCore.NodeRegistry.register(node_id, name, self(), %{
      type: get_field(node, :type),
      capabilities: get_field(node, :capabilities) || %{}
    })
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

  # Direct in-process callers do not have a network peer and keep the local
  # compatibility behavior. The HTTP router always supplies the actual socket
  # peer, so non-loopback clients cannot inherit an unauthenticated operator.
  defp local_peer?(nil), do: true
  defp local_peer?({127, _b, _c, _d}), do: true
  defp local_peer?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp local_peer?({0, 0, 0, 0, 0, 65_535, mapped_prefix, _last})
       when mapped_prefix in 0x7F00..0x7FFF,
       do: true

  defp local_peer?(_peer), do: false

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
          subscription_mode: state.subscription_mode,
          subscriptions: state.subscriptions
        })
    end
  end

  defp update_presence_subscriptions(state) do
    case Process.whereis(LemonControlPlane.Presence) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        LemonControlPlane.Presence.update_subscriptions(
          state.conn_id,
          state.subscription_mode,
          state.subscriptions
        )
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
