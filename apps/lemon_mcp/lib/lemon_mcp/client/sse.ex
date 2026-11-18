defmodule LemonMCP.Client.SSE do
  # Same bound as LemonMCP.Framing.Stdio: one unterminated line, and one
  # event's accumulated field lines.
  @max_sse_bytes 8 * 1024 * 1024

  @moduledoc """
  MCP client GenServer for legacy HTTP+SSE MCP servers.

  This transport is kept for compatibility with older MCP servers. It opens the
  server-sent event stream, waits for the server `endpoint` event, sends
  JSON-RPC messages to that endpoint, and reads JSON-RPC responses from SSE
  `message` events.

  Both the stream and every POST go through `LemonCore.Net.HTTP`: redirects are
  never followed (a 3xx is an error) and each connection is pinned. With an
  `:origin_policy` every destination is authorized and pinned by
  `LemonMCP.HTTP.OriginPolicy.pin/3`; without one the shared address policy
  applies, permitting only the operator-configured host to be private (never
  metadata). The `endpoint` event is resolved against the stream URL and must
  share the configured URL's origin, so configured headers (credentials) only
  ever reach that origin. A reader process owns the stream connection and
  forwards body chunks on demand: it sends one batch, then waits for the
  client's ack before reading more, so a fast server is held back by TCP flow
  control instead of filling the client's mailbox.

  Stream bounds match the stdio framing limit: an unterminated line may hold at
  most #{@max_sse_bytes} bytes (`:sse_line_too_long`) and one event's field
  lines at most #{@max_sse_bytes} bytes (`:sse_event_too_large`). Overflow
  closes the stream and fails with `{:sse_stream_failed, reason}`.
  """

  use GenServer
  require Logger

  alias LemonCore.Net.HTTP
  alias LemonMCP.HTTP.OriginPolicy
  alias LemonMCP.Protocol

  @type client_state :: :disconnected | :initializing | :ready

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    gen_opts = Keyword.take(opts, [:name, :timeout])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @spec state(GenServer.server()) :: client_state()
  def state(server), do: GenServer.call(server, :get_state)

  @spec list_tools(GenServer.server(), timeout()) ::
          {:ok, [Protocol.tool()]} | {:error, term()}
  def list_tools(server, timeout \\ 30_000), do: GenServer.call(server, :list_tools, timeout)

  @spec call_tool(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, [Protocol.content_item()]} | {:error, term()}
  def call_tool(server, tool_name, arguments \\ %{}, timeout \\ 30_000) do
    GenServer.call(server, {:call_tool, tool_name, arguments}, timeout)
  end

  @spec list_resources(GenServer.server(), timeout()) :: {:ok, [map()]} | {:error, term()}
  def list_resources(server, timeout \\ 30_000),
    do: GenServer.call(server, :list_resources, timeout)

  @spec read_resource(GenServer.server(), String.t(), timeout()) ::
          {:ok, [map()]} | {:error, term()}
  def read_resource(server, uri, timeout \\ 30_000) do
    GenServer.call(server, {:read_resource, uri}, timeout)
  end

  @spec list_prompts(GenServer.server(), timeout()) :: {:ok, [map()]} | {:error, term()}
  def list_prompts(server, timeout \\ 30_000), do: GenServer.call(server, :list_prompts, timeout)

  @spec get_prompt(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def get_prompt(server, prompt_name, arguments \\ %{}, timeout \\ 30_000) do
    GenServer.call(server, {:get_prompt, prompt_name, arguments}, timeout)
  end

  @spec close(GenServer.server()) :: :ok
  def close(server), do: GenServer.call(server, :close)

  @spec server_info(GenServer.server()) :: {:ok, map()} | {:error, :not_connected}
  def server_info(server), do: GenServer.call(server, :server_info)

  @spec server_capabilities(GenServer.server()) :: {:ok, map()} | {:error, :not_connected}
  def server_capabilities(server), do: GenServer.call(server, :server_capabilities)

  @impl true
  def init(opts) do
    config = %{
      url: Keyword.fetch!(opts, :url),
      headers: Keyword.get(opts, :headers, []),
      client_name: Keyword.get(opts, :client_name, "lemon-mcp"),
      client_version: Keyword.get(opts, :client_version, "0.1.0"),
      capabilities: Keyword.get(opts, :capabilities, %{}),
      notification_handler: Protocol.notification_handler(opts),
      timeout_ms: Keyword.get(opts, :timeout_ms, 30_000),
      origin_policy: Keyword.get(opts, :origin_policy),
      peer_owner:
        Keyword.get(opts, :peer_owner, &LemonCore.LoopbackListener.peer_owned_by_self?/2)
    }

    {:ok, task_supervisor} = Protocol.start_notification_supervisor(opts)

    state = %{
      state: :initializing,
      task_supervisor: task_supervisor,
      config: config,
      stream_reader: nil,
      post_url: nil,
      sse_buffer: "",
      sse_event_bytes: 0,
      sse_event: LemonMCP.Client.SSE.Stream.new_event(),
      server_info: nil,
      server_capabilities: nil
    }

    with :ok <- ensure_http_apps(),
         {:ok, state} <- open_stream(state) do
      initialize_stream(state)
    else
      {:error, reason} ->
        Protocol.stop_notification_supervisor(task_supervisor)
        {:stop, reason}
    end
  end

  defp initialize_stream(state) do
    with {:ok, state} <- await_endpoint(state),
         {:ok, state} <- initialize(state),
         {:ok, state} <- send_initialized_notification(state) do
      {:ok, %{state | state: :ready}}
    else
      {:error, reason} ->
        close_stream(state)
        Protocol.stop_notification_supervisor(state.task_supervisor)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.state, state}
  end

  @impl true
  def handle_call(:list_tools, _from, %{state: :ready} = state) do
    {reply, state} =
      request_response(state, Protocol.tool_list_request(), fn
        %Protocol.ToolListResponse{result: result, error: nil} -> {:ok, result.tools}
        other -> normalize_reply({:ok, other})
      end)

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    {:reply, {:error, {:not_ready, state.state}}, state}
  end

  @impl true
  def handle_call({:call_tool, tool_name, arguments}, _from, %{state: :ready} = state) do
    request = Protocol.tool_call_request(name: tool_name, arguments: arguments)

    {reply, state} =
      request_response(state, request, fn
        %Protocol.ToolCallResponse{result: result, error: nil} ->
          if result.isError do
            {:error, {:tool_error, result.content}}
          else
            {:ok, result.content}
          end

        other ->
          normalize_reply({:ok, other})
      end)

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:call_tool, _tool_name, _arguments}, _from, state) do
    {:reply, {:error, {:not_ready, state.state}}, state}
  end

  @impl true
  def handle_call(:list_resources, _from, %{state: :ready} = state) do
    {reply, state} =
      request_response(state, Protocol.resource_list_request(), fn
        %Protocol.ResourceListResponse{result: result, error: nil} -> {:ok, result.resources}
        other -> normalize_reply({:ok, other})
      end)

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:list_resources, _from, state) do
    {:reply, {:error, {:not_ready, state.state}}, state}
  end

  @impl true
  def handle_call({:read_resource, uri}, _from, %{state: :ready} = state) do
    request = Protocol.resource_read_request(uri: uri)

    {reply, state} =
      request_response(state, request, fn
        %Protocol.ResourceReadResponse{result: result, error: nil} -> {:ok, result.contents}
        other -> normalize_reply({:ok, other})
      end)

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:read_resource, _uri}, _from, state) do
    {:reply, {:error, {:not_ready, state.state}}, state}
  end

  @impl true
  def handle_call(:list_prompts, _from, %{state: :ready} = state) do
    {reply, state} =
      request_response(state, Protocol.prompt_list_request(), fn
        %Protocol.PromptListResponse{result: result, error: nil} -> {:ok, result.prompts}
        other -> normalize_reply({:ok, other})
      end)

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:list_prompts, _from, state) do
    {:reply, {:error, {:not_ready, state.state}}, state}
  end

  @impl true
  def handle_call({:get_prompt, prompt_name, arguments}, _from, %{state: :ready} = state) do
    request = Protocol.prompt_get_request(name: prompt_name, arguments: arguments)

    {reply, state} =
      request_response(state, request, fn
        %Protocol.PromptGetResponse{result: result, error: nil} -> {:ok, result}
        other -> normalize_reply({:ok, other})
      end)

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:get_prompt, _prompt_name, _arguments}, _from, state) do
    {:reply, {:error, {:not_ready, state.state}}, state}
  end

  @impl true
  def handle_call(:close, _from, state) do
    close_stream(state)
    {:stop, :normal, :ok, %{state | state: :disconnected, stream_reader: nil}}
  end

  @impl true
  def handle_call(:server_info, _from, %{state: :ready, server_info: info} = state) do
    {:reply, {:ok, info}, state}
  end

  @impl true
  def handle_call(:server_info, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl true
  def handle_call(
        :server_capabilities,
        _from,
        %{state: :ready, server_capabilities: caps} = state
      ) do
    {:reply, {:ok, caps || %{}}, state}
  end

  @impl true
  def handle_call(:server_capabilities, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl true
  def handle_info({:mcp_sse, reader, message}, %{stream_reader: reader} = state) do
    case stream_events(message, state) do
      {:ok, _events, state} ->
        {:noreply, state}

      {:error, _reason, state} ->
        {:stop, :normal, %{state | state: :disconnected, stream_reader: nil}}
    end
  end

  def handle_info({:mcp_stream_closed, reader}, %{stream_reader: reader} = state) do
    {:stop, :normal, %{state | state: :disconnected, stream_reader: nil}}
  end

  def handle_info(_message, state) do
    Logger.debug("Ignoring unexpected MCP SSE client message")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    close_stream(state)
    Protocol.stop_notification_supervisor(state.task_supervisor)
  end

  defp open_stream(state) do
    url = state.config.url

    headers = [
      {"accept", "text/event-stream"}
      | Enum.map(state.config.headers, fn {key, value} -> {to_string(key), to_string(value)} end)
    ]

    with {:ok, pin} <- OriginPolicy.pin(url, state.config.origin_policy),
         {:ok, stream} <-
           HTTP.open_stream(:get, url, [headers: headers] ++ request_opts(url, pin, state)) do
      if stream.status == 200 do
        {:ok, %{state | stream_reader: start_reader(stream)}}
      else
        HTTP.close_stream(stream)
        {:error, {:sse_stream_failed, {:http_status, stream.status}}}
      end
    else
      {:error, reason} -> {:error, {:sse_stream_failed, reason}}
    end
  end

  # The reader owns the Mint connection (its passive socket is read with
  # `stream_next/2`). It forwards one chunk batch, then waits for the client's
  # `:mcp_sse_ack` before reading again. It monitors this client and closes the
  # stream when the client exits.
  defp start_reader(stream) do
    parent = self()

    reader =
      spawn(fn ->
        monitor = Process.monitor(parent)

        receive do
          {:mcp_sse_stream, stream} -> read_loop(parent, monitor, stream)
        end
      end)

    {:ok, conn} = Mint.HTTP.controlling_process(stream.conn, reader)
    send(reader, {:mcp_sse_stream, %{stream | conn: conn}})
    reader
  end

  defp read_loop(parent, monitor, stream) do
    receive do
      {:DOWN, ^monitor, :process, _pid, _reason} -> HTTP.close_stream(stream)
    after
      0 ->
        case HTTP.stream_next(stream, 1_000) do
          {:ok, stream, chunks} ->
            if forward_chunks(parent, monitor, chunks) == :ok,
              do: read_loop(parent, monitor, stream),
              else: HTTP.close_stream(stream)

          {:done, stream, chunks} ->
            if forward_chunks(parent, monitor, chunks) == :ok,
              do: send(parent, {:mcp_sse, self(), :done})

            HTTP.close_stream(stream)

          {:error, :timeout} ->
            read_loop(parent, monitor, stream)

          {:error, reason} ->
            send(parent, {:mcp_sse, self(), {:error, reason}})
            HTTP.close_stream(stream)
        end
    end
  end

  defp forward_chunks(_parent, _monitor, []), do: :ok

  defp forward_chunks(parent, monitor, chunks) do
    send(parent, {:mcp_sse, self(), {:chunks, chunks}})

    receive do
      :mcp_sse_ack -> :ok
      {:DOWN, ^monitor, :process, _pid, _reason} -> :parent_down
    end
  end

  defp await_endpoint(state) do
    deadline = deadline(state.config.timeout_ms)

    result =
      receive_sse_until(state, deadline, fn
        %{event: "endpoint", data: endpoint}, state ->
          case resolve_endpoint(state.config.url, endpoint) do
            {:ok, post_url} -> {:matched_state, %{state | post_url: post_url}}
            {:error, reason} -> {:matched, {:error, reason}}
          end

        _event, _state ->
          :cont
      end)

    case result do
      {:ok, state} -> {:ok, state}
      {:error, reason, _state} -> {:error, reason}
    end
  end

  defp initialize(state) do
    request =
      Protocol.initialize_request(
        client_name: state.config.client_name,
        client_version: state.config.client_version,
        capabilities: state.config.capabilities
      )

    {reply, state} =
      request_response(state, request, fn
        %Protocol.InitializeResponse{result: result, error: nil} -> {:ok, result}
        other -> normalize_reply({:ok, other})
      end)

    case reply do
      {:ok, result} ->
        {:ok, %{state | server_info: result.serverInfo, server_capabilities: result.capabilities}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_initialized_notification(state) do
    case post_raw(Protocol.initialized_notification(), state) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_response(state, request, mapper) do
    with :ok <- post_raw(request, state),
         {:ok, id} <- message_id(request) do
      case receive_response(state, id) do
        {{:ok, response}, state} -> {mapper.(response), state}
        {{:error, reason}, state} -> {{:error, reason}, state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp receive_response(state, id) do
    deadline = deadline(state.config.timeout_ms)

    result =
      receive_sse_until(state, deadline, fn
        %{event: "message", data: data}, _state ->
          with {:ok, decoded} <- Protocol.decode(data),
               true <- response_id(decoded) == id do
            {:matched, normalize_reply({:ok, decoded})}
          else
            false -> :cont
            {:error, reason} -> {:matched, {:error, {:decode_error, reason}}}
          end

        _event, _state ->
          :cont
      end)

    case result do
      {:ok, response, state} -> {{:ok, response}, state}
      {:error, reason, state} -> {{:error, reason}, state}
    end
  end

  defp receive_sse_until(state, deadline, matcher) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)
    reader = state.stream_reader

    receive do
      {:mcp_sse, ^reader, message} ->
        case stream_events(message, state) do
          {:ok, events, state} -> match_events(events, state, deadline, matcher)
          {:error, reason, state} -> {:error, reason, state}
        end

      {:mcp_stream_closed, ^reader} ->
        {:error, :sse_stream_closed, %{state | state: :disconnected}}
    after
      timeout ->
        {:error, :timeout, state}
    end
  end

  defp stream_events({:chunks, chunks}, state) do
    send(state.stream_reader, :mcp_sse_ack)

    result =
      Enum.reduce_while(chunks, {:ok, [], state}, fn chunk, {:ok, events, state} ->
        case parse_sse_chunk(state, chunk) do
          {:ok, new_events, state} -> {:cont, {:ok, Enum.reverse(new_events, events), state}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, events, state} ->
        {:ok, Enum.reverse(events), state}

      {:error, reason} ->
        close_stream(state)
        send(self(), {:mcp_stream_closed, state.stream_reader})
        {:error, {:sse_stream_failed, reason}, state}
    end
  end

  defp stream_events(:done, state) do
    send(self(), {:mcp_stream_closed, state.stream_reader})
    {:ok, [], state}
  end

  defp stream_events({:error, reason}, state) do
    send(self(), {:mcp_stream_closed, state.stream_reader})
    {:error, {:sse_stream_failed, reason}, state}
  end

  defp match_events([], state, deadline, matcher), do: receive_sse_until(state, deadline, matcher)

  defp match_events([event | rest], state, deadline, matcher) do
    case matcher.(event, state) do
      {:matched_state, matched_state} ->
        {:ok, matched_state}

      {:matched, {:ok, value}} ->
        {:ok, value, state}

      {:matched, {:error, reason}} ->
        {:error, reason, state}

      {:matched, value} ->
        {:ok, value, state}

      :cont ->
        match_events(rest, state, deadline, matcher)
    end
  end

  # Only the new chunk is split; the pending partial line is completed by its
  # first piece. Field-line bytes count toward the current event until a blank
  # line dispatches it.
  defp parse_sse_chunk(state, chunk) do
    [first | rest] = :binary.split(chunk, "\n", [:global])

    {complete_lines, buffer} =
      case rest do
        [] -> {[], state.sse_buffer <> first}
        _ -> {[state.sse_buffer <> first | Enum.drop(rest, -1)], List.last(rest)}
      end

    with :ok <- check_line(buffer),
         {:ok, event_bytes} <- count_event_bytes(complete_lines, state.sse_event_bytes) do
      {events, event} =
        LemonMCP.Client.SSE.Stream.parse_lines(complete_lines, state.sse_event)

      Enum.each(events, &dispatch_event(&1, state))

      {:ok, Enum.reverse(events),
       %{state | sse_buffer: buffer, sse_event: event, sse_event_bytes: event_bytes}}
    end
  end

  defp check_line(buffer) when byte_size(buffer) > @max_sse_bytes,
    do: {:error, :sse_line_too_long}

  defp check_line(_buffer), do: :ok

  defp count_event_bytes([], bytes), do: {:ok, bytes}

  defp count_event_bytes([line | rest], bytes) do
    case line do
      blank when blank in ["", "\r"] ->
        count_event_bytes(rest, 0)

      _ when byte_size(line) > @max_sse_bytes ->
        {:error, :sse_line_too_long}

      _ when bytes + byte_size(line) > @max_sse_bytes ->
        {:error, :sse_event_too_large}

      _ ->
        count_event_bytes(rest, bytes + byte_size(line))
    end
  end

  defp dispatch_event(%{event: "message", data: data}, state) do
    case Jason.decode(data) do
      {:ok, message} ->
        Protocol.dispatch_notification(
          message,
          state.config.notification_handler,
          state.task_supervisor
        )

      _ ->
        :ok
    end
  end

  defp dispatch_event(_event, _state), do: :ok

  defp post_raw(message, state) do
    with {:ok, body} <- Protocol.encode(message),
         {:ok, post_url} <- require_post_url(state),
         {:ok, pin} <- OriginPolicy.pin(post_url, state.config.origin_policy) do
      headers =
        [{"content-type", "application/json"}] ++
          Enum.reject(state.config.headers, fn {key, _} ->
            String.downcase(to_string(key)) == "content-type"
          end)

      opts =
        [headers: headers, body: body, max_redirects: 0] ++ request_opts(post_url, pin, state)

      case HTTP.request(:post, post_url, opts) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status, body: response_body}} ->
          {:error, {:http_error, status, response_body}}

        {:error, reason} ->
          {:error, {:http_request_failed, reason}}
      end
    end
  end

  # A policy pin carries the authorized address. Without a policy the shared
  # address policy resolves each connection; only the configured host (the
  # endpoint is bound to its origin) may be private, never metadata.
  defp request_opts(_url, %{address: address} = pin, state) do
    peer_check = if OriginPolicy.ownership_required?(pin), do: state.config.peer_owner
    [address: address, peer_check: peer_check, timeout_ms: state.config.timeout_ms]
  end

  defp request_opts(url, nil, state) do
    [allow_private_hosts: [URI.parse(url).host], timeout_ms: state.config.timeout_ms]
  end

  defp normalize_reply({:ok, %{error: error}}) when not is_nil(error),
    do: {:error, {:rpc_error, error}}

  defp normalize_reply({:ok, value}), do: {:ok, value}

  defp response_id(%{id: id}), do: id
  defp response_id(_), do: nil

  defp message_id(%{id: id}) when not is_nil(id), do: {:ok, id}
  defp message_id(_), do: {:error, :missing_request_id}

  defp require_post_url(%{post_url: url}) when is_binary(url), do: {:ok, url}
  defp require_post_url(_state), do: {:error, :missing_sse_endpoint}

  # Relative endpoints resolve against the stream URL; the result must keep the
  # configured server's exact origin, or credentials could be sent elsewhere.
  defp resolve_endpoint(base_url, endpoint) when is_binary(endpoint) do
    resolved = base_url |> URI.parse() |> URI.merge(endpoint) |> URI.to_string()

    with {:ok, origin} <- OriginPolicy.canonical_origin(base_url),
         {:ok, ^origin} <- OriginPolicy.canonical_origin(resolved) do
      {:ok, resolved}
    else
      _ -> {:error, :sse_endpoint_origin_mismatch}
    end
  rescue
    _ -> {:error, :sse_endpoint_origin_mismatch}
  end

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp close_stream(%{stream_reader: reader}) when is_pid(reader) do
    Process.exit(reader, :kill)
    :ok
  end

  defp close_stream(_state), do: :ok

  defp ensure_http_apps do
    case Application.ensure_all_started(:ssl) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
