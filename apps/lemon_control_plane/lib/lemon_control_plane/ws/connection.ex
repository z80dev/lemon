defmodule LemonControlPlane.WS.Connection do
  @moduledoc """
  WebSocket connection handler for the control plane.

  Implements the OpenClaw-compatible WebSocket protocol with:

  - Handshake via `connect` method followed by `hello-ok` frame
  - Request/response frame handling
  - Event broadcasting
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
  alias LemonControlPlane.Methods.Registry

  defstruct [
    :conn_id,
    :auth,
    :connected,
    :event_seq,
    :state_version,
    :subscriptions
  ]

  @type t :: %__MODULE__{
          conn_id: String.t(),
          auth: Authorize.auth_context() | nil,
          connected: boolean(),
          event_seq: non_neg_integer(),
          state_version: map(),
          subscriptions: MapSet.t()
        }

  ## WebSock Callbacks

  @impl WebSock
  def init(_opts) do
    conn_id = UUID.uuid4()

    state = %__MODULE__{
      conn_id: conn_id,
      auth: nil,
      connected: false,
      event_seq: 0,
      state_version: %{},
      subscriptions: MapSet.new()
    }

    Logger.debug("WebSocket connection initialized: #{conn_id}")

    {:ok, state}
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    case Frames.parse(text) do
      {:ok, frame} ->
        handle_frame(frame, state)

      {:error, {:json_decode_error, reason}} ->
        error = Errors.invalid_request("Invalid JSON: #{reason}")
        {:push, {:text, Frames.encode_response("unknown", {:error, error})}, state}

      {:error, {:invalid_frame, reason}} ->
        error = Errors.invalid_request(reason)
        {:push, {:text, Frames.encode_response("unknown", {:error, error})}, state}
    end
  end

  def handle_in({_data, [opcode: :binary]}, state) do
    error = Errors.invalid_request("Binary frames not supported")
    {:push, {:text, Frames.encode_response("unknown", {:error, error})}, state}
  end

  @impl WebSock
  def handle_info({:event, event_name, payload}, state) do
    # Push event to client (3-tuple format - no state version update)
    state = increment_event_seq(state)
    frame = Frames.encode_event(event_name, payload, state.event_seq, state.state_version)
    {:push, {:text, frame}, state}
  end

  def handle_info({:event, event_name, payload, new_state_version}, state) when is_map(new_state_version) do
    # Push event to client (4-tuple format from EventBridge with state version)
    state = increment_event_seq(state)
    # Update state version from EventBridge
    state = %{state | state_version: Map.merge(state.state_version, new_state_version)}
    frame = Frames.encode_event(event_name, payload, state.event_seq, state.state_version)
    {:push, {:text, frame}, state}
  end

  def handle_info({:push_frame, frame}, state) when is_binary(frame) do
    {:push, {:text, frame}, state}
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
    case Authorize.from_params(params || %{}) do
      {:ok, auth} ->
        state = %{state | auth: auth, connected: true}

        # Register with presence
        register_presence(state)

        # Build hello-ok response - parity requires ONLY hello-ok, not a normal res frame
        hello_ok =
          Frames.encode_hello_ok(%{
            conn_id: state.conn_id,
            methods: Registry.list_methods(),
            events: Frames.supported_events(),
            snapshot: build_snapshot(state),
            auth: build_auth_response(auth)
          })

        Logger.info("WebSocket connection established: #{state.conn_id}, role: #{auth.role}")

        # Only send hello-ok, NOT an additional res frame (parity requirement)
        {:push, {:text, hello_ok}, state}

      {:error, reason} ->
        error = Errors.unauthorized(inspect(reason))
        # For auth errors, we still send a res frame with the error
        {:push, {:text, Frames.encode_response(id, {:error, error})}, state}
    end
  end

  ## Method Dispatch

  defp handle_method(id, method, params, state) do
    ctx = %{
      auth: state.auth,
      conn_id: state.conn_id,
      conn_pid: self()
    }

    result = Registry.dispatch(method, params, ctx)
    response = Frames.encode_response(id, result)

    {:push, {:text, response}, state}
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

    # Helpful for nodes: when authenticated via token, client_id is set to nodeId/deviceId.
    if auth.client_id do
      Map.put(base, "clientId", auth.client_id)
    else
      base
    end
  end

  defp register_presence(state) do
    case Process.whereis(LemonControlPlane.Presence) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        LemonControlPlane.Presence.register(state.conn_id, %{
          role: state.auth.role,
          client_id: state.auth.client_id,
          pid: self()
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
