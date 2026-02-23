defmodule LemonControlPlane.Protocol.Frames do
  @moduledoc """
  Frame types for the Lemon control-plane WebSocket protocol.

  The protocol uses JSON-encoded frames with the following types:

  - `req` - Request frame (client to server)
  - `res` - Response frame (server to client)
  - `event` - Event frame (server to client)
  - `hello-ok` - Handshake completion (server to client)

  ## Request Frame

      %{
        "type" => "req",
        "id" => "<uuid>",
        "method" => "<method_name>",
        "params" => %{...}  # optional
      }

  ## Response Frame

      %{
        "type" => "res",
        "id" => "<uuid>",  # matches request id
        "ok" => true | false,
        "payload" => %{...},  # present when ok: true
        "error" => %{...}     # present when ok: false
      }

  ## Event Frame

      %{
        "type" => "event",
        "event" => "<event_name>",
        "payload" => %{...},  # optional
        "seq" => <integer>,   # sequence number
        "stateVersion" => %{...}  # optional, for client reconciliation
      }

  ## Hello-OK Frame

      %{
        "type" => "hello-ok",
        "protocol" => 1,
        "server" => %{...},
        "features" => %{...},
        "snapshot" => %{...},
        "policy" => %{...},
        "auth" => %{...}  # optional
      }
  """

  alias LemonControlPlane.Protocol.Errors

  @type request :: %{
          type: :req,
          id: String.t(),
          method: String.t(),
          params: map() | nil
        }

  @type response :: %{
          type: :res,
          id: String.t(),
          ok: boolean(),
          payload: term() | nil,
          error: Errors.error_payload() | nil
        }

  @type event :: %{
          type: :event,
          event: String.t(),
          payload: term() | nil,
          seq: non_neg_integer(),
          state_version: map() | nil
        }

  @type hello_ok :: %{
          type: :hello_ok,
          protocol: pos_integer(),
          server: map(),
          features: map(),
          snapshot: map(),
          policy: map(),
          auth: map() | nil
        }

  @type frame :: request() | response() | event() | hello_ok()

  @doc """
  Parses a JSON-encoded frame from the client.

  Returns `{:ok, frame}` or `{:error, reason}`.
  """
  @spec parse(binary()) :: {:ok, request()} | {:error, term()}
  def parse(data) when is_binary(data) do
    with {:ok, decoded} <- Jason.decode(data),
         {:ok, frame} <- validate_request(decoded) do
      {:ok, frame}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:json_decode_error, Exception.message(error)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_request(%{"type" => "req", "id" => id, "method" => method} = frame)
       when is_binary(id) and is_binary(method) do
    {:ok,
     %{
       type: :req,
       id: id,
       method: method,
       params: Map.get(frame, "params")
     }}
  end

  defp validate_request(%{"type" => "req"}) do
    {:error, {:invalid_frame, "request frame must have id and method"}}
  end

  defp validate_request(%{"type" => type}) when type != "req" do
    {:error, {:invalid_frame, "expected request frame, got: #{type}"}}
  end

  defp validate_request(_) do
    {:error, {:invalid_frame, "frame must have type field"}}
  end

  @doc """
  Encodes a response frame to JSON.
  """
  @spec encode_response(String.t(), {:ok, term()} | {:error, term()}) :: binary()
  def encode_response(id, {:ok, payload}) do
    Jason.encode!(%{
      "type" => "res",
      "id" => id,
      "ok" => true,
      "payload" => payload
    })
  end

  def encode_response(id, {:error, error}) do
    error_payload = Errors.to_payload(error)

    Jason.encode!(%{
      "type" => "res",
      "id" => id,
      "ok" => false,
      "error" => error_payload
    })
  end

  @doc """
  Encodes an event frame to JSON.
  """
  @spec encode_event(String.t(), term(), non_neg_integer(), map() | nil) :: binary()
  def encode_event(event_name, payload, seq, state_version \\ nil) do
    frame = %{
      "type" => "event",
      "event" => event_name,
      "seq" => seq
    }

    frame =
      if payload do
        Map.put(frame, "payload", payload)
      else
        frame
      end

    frame =
      if state_version do
        Map.put(frame, "stateVersion", state_version)
      else
        frame
      end

    Jason.encode!(frame)
  end

  @doc """
  Encodes a hello-ok frame to JSON.

  This frame is sent after successful handshake to complete the connection.
  """
  @spec encode_hello_ok(map()) :: binary()
  def encode_hello_ok(opts) do
    frame = %{
      "type" => "hello-ok",
      "protocol" => opts[:protocol] || LemonControlPlane.protocol_version(),
      "server" => %{
        "version" => opts[:version] || LemonControlPlane.server_version(),
        "commit" => opts[:commit] || LemonControlPlane.git_commit(),
        "host" => opts[:host] || hostname(),
        "connId" => opts[:conn_id]
      },
      "features" => %{
        "methods" => opts[:methods] || [],
        "events" => opts[:events] || []
      },
      "snapshot" => opts[:snapshot] || %{},
      "policy" => %{
        "maxPayload" => opts[:max_payload] || 1_048_576,
        "maxBufferedBytes" => opts[:max_buffered_bytes] || 8_388_608,
        "tickIntervalMs" => opts[:tick_interval_ms] || 1000
      }
    }

    frame =
      if opts[:auth] do
        Map.put(frame, "auth", opts[:auth])
      else
        frame
      end

    Jason.encode!(frame)
  end

  defp hostname do
    {:ok, hostname} = :inet.gethostname()
    to_string(hostname)
  end

  @doc """
  Returns a list of supported event names.

  These must be kept in sync with the events mapped in EventBridge.
  """
  @spec supported_events() :: [String.t()]
  def supported_events do
    [
      # Run/Agent events
      "agent",
      "chat",
      # Presence
      "presence",
      # System events
      "tick",
      "talk.mode",
      "shutdown",
      "health",
      "heartbeat",
      # Cron events
      "cron",
      "cron.job",
      # Task / run-graph events
      "task.started",
      "task.completed",
      "task.error",
      "task.timeout",
      "task.aborted",
      "run.graph.changed",
      # Node events
      "node.pair.requested",
      "node.pair.resolved",
      "node.invoke.request",
      "node.invoke.completed",
      # Device events
      "device.pair.requested",
      "device.pair.resolved",
      # Voicewake events
      "voicewake.changed",
      # Approval events
      "exec.approval.requested",
      "exec.approval.resolved",
      # Custom events (from system-event with custom_* types)
      "custom"
    ]
  end
end
