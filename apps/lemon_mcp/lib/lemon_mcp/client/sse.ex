defmodule LemonMCP.Client.SSE do
  @moduledoc """
  MCP client GenServer for legacy HTTP+SSE MCP servers.

  This transport is kept for compatibility with older MCP servers. It opens the
  server-sent event stream, waits for the server `endpoint` event, sends
  JSON-RPC messages to that endpoint, and reads JSON-RPC responses from SSE
  `message` events. The stream uses Mint so the initial event is delivered even
  when HTTP headers and the first chunk arrive in the same TCP packet.
  """

  use GenServer
  require Logger

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
      timeout_ms: Keyword.get(opts, :timeout_ms, 30_000)
    }

    state = %{
      state: :initializing,
      config: config,
      stream_request_id: nil,
      stream_conn: nil,
      stream_socket: nil,
      post_url: nil,
      sse_buffer: "",
      sse_event: new_event(),
      server_info: nil,
      server_capabilities: nil
    }

    with :ok <- ensure_http_apps(),
         {:ok, state} <- open_stream(state) do
      initialize_stream(state)
    else
      {:error, reason} -> {:stop, reason}
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
    {:stop, :normal, :ok, %{state | state: :disconnected, stream_request_id: nil}}
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
  def handle_info({protocol, socket, _data} = message, %{stream_socket: socket} = state)
      when protocol in [:tcp, :ssl, :tcp_error, :ssl_error] do
    handle_stream_message(message, state)
  end

  def handle_info({protocol, socket} = message, %{stream_socket: socket} = state)
      when protocol in [:tcp_closed, :ssl_closed] do
    handle_stream_message(message, state)
  end

  def handle_info({:mcp_stream_closed, request_id}, %{stream_request_id: request_id} = state) do
    {:stop, :normal, %{state | state: :disconnected, stream_request_id: nil}}
  end

  def handle_info(_message, state) do
    Logger.debug("Ignoring unexpected MCP SSE client message")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state), do: close_stream(state)

  defp handle_stream_message(message, state) do
    case stream_events(message, state) do
      {:ok, _events, state} ->
        {:noreply, state}

      {:error, _reason, state} ->
        {:stop, :normal, %{state | state: :disconnected, stream_request_id: nil}}
    end
  end

  defp open_stream(state) do
    uri = URI.parse(state.config.url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    timeout = state.config.timeout_ms

    headers =
      [
        {"accept", "text/event-stream"}
        | Enum.map(state.config.headers, fn {key, value} -> {to_string(key), to_string(value)} end)
      ]

    path = if uri.path in [nil, ""], do: "/", else: uri.path
    path = if uri.query, do: path <> "?" <> uri.query, else: path

    # httpc can retain the first chunk until another TCP packet arrives. An SSE
    # server waits for our initialize POST after sending endpoint, so that stalls
    # both sides indefinitely. Mint emits decoded data from the initial packet.
    case Mint.HTTP.connect(scheme, uri.host, uri.port,
           protocols: [:http1],
           transport_opts: [timeout: timeout]
         ) do
      {:ok, conn} ->
        case Mint.HTTP.request(conn, "GET", path, headers, nil) do
          {:ok, conn, request_id} ->
            {:ok,
             %{
               state
               | stream_conn: conn,
                 stream_socket: Mint.HTTP.get_socket(conn),
                 stream_request_id: request_id
             }}

          {:error, conn, reason} ->
            {:ok, _conn} = Mint.HTTP.close(conn)
            {:error, {:sse_stream_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:sse_stream_failed, reason}}
    end
  end

  defp await_endpoint(state) do
    deadline = deadline(state.config.timeout_ms)

    result =
      receive_sse_until(state, deadline, fn
        %{event: "endpoint", data: endpoint}, state ->
          {:matched_state, %{state | post_url: resolve_endpoint(state.config.url, endpoint)}}

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

    receive do
      {protocol, socket, _data} = message
      when protocol in [:tcp, :ssl, :tcp_error, :ssl_error] and socket == state.stream_socket ->
        receive_stream_message(message, state, deadline, matcher)

      {protocol, socket} = message
      when protocol in [:tcp_closed, :ssl_closed] and socket == state.stream_socket ->
        receive_stream_message(message, state, deadline, matcher)

      {:mcp_stream_closed, request_id} when request_id == state.stream_request_id ->
        {:error, :sse_stream_closed, %{state | state: :disconnected}}
    after
      timeout ->
        {:error, :timeout, state}
    end
  end

  defp receive_stream_message(message, state, deadline, matcher) do
    case stream_events(message, state) do
      {:ok, events, state} -> match_events(events, state, deadline, matcher)
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  defp stream_events(message, state) do
    case Mint.HTTP.stream(state.stream_conn, message) do
      {:ok, conn, responses} ->
        collect_stream_events(responses, %{state | stream_conn: conn}, [])

      {:error, conn, reason, _responses} ->
        send(self(), {:mcp_stream_closed, state.stream_request_id})
        {:error, {:sse_stream_failed, reason}, %{state | stream_conn: conn}}
    end
  end

  defp collect_stream_events([], state, events), do: {:ok, Enum.reverse(events), state}

  defp collect_stream_events(
         [{:data, ref, data} | rest],
         %{stream_request_id: ref} = state,
         events
       ) do
    {new_events, state} = parse_sse_chunk(state, data)
    collect_stream_events(rest, state, Enum.reverse(new_events, events))
  end

  defp collect_stream_events(
         [{:status, ref, status} | _],
         %{stream_request_id: ref} = state,
         _events
       )
       when status != 200 do
    {:error, {:sse_stream_failed, {:http_status, status}}, state}
  end

  defp collect_stream_events([{:done, ref} | rest], %{stream_request_id: ref} = state, events) do
    send(self(), {:mcp_stream_closed, ref})
    collect_stream_events(rest, state, events)
  end

  defp collect_stream_events([_response | rest], state, events),
    do: collect_stream_events(rest, state, events)

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

  defp parse_sse_chunk(state, chunk) do
    combined = state.sse_buffer <> chunk
    lines = String.split(combined, "\n")

    # The final split element is an unfinished line, including "" after a
    # trailing newline. Only an actual empty line dispatches an SSE event.
    complete_lines = Enum.drop(lines, -1)
    buffer = List.last(lines) || ""

    {events, event} =
      Enum.reduce(complete_lines, {[], state.sse_event}, fn line, {events, event} ->
        parse_sse_line(String.trim_trailing(line, "\r"), events, event)
      end)

    Enum.each(events, fn
      %{event: "message", data: data} ->
        case Jason.decode(data) do
          {:ok, message} ->
            Protocol.dispatch_notification(message, state.config.notification_handler)

          _ ->
            :ok
        end

      _ ->
        :ok
    end)

    {Enum.reverse(events), %{state | sse_buffer: buffer, sse_event: event}}
  end

  defp parse_sse_line("", events, %{data: data} = event) when data != [] do
    {[%{event: event.event || "message", data: Enum.reverse(data) |> Enum.join("\n")} | events],
     new_event()}
  end

  defp parse_sse_line("", events, _event), do: {events, new_event()}
  defp parse_sse_line(":" <> _comment, events, event), do: {events, event}

  defp parse_sse_line("event:" <> value, events, event) do
    {events, %{event | event: trim_sse_value(value)}}
  end

  defp parse_sse_line("data:" <> value, events, event) do
    {events, %{event | data: [trim_sse_value(value) | event.data]}}
  end

  defp parse_sse_line(_line, events, event), do: {events, event}

  defp new_event, do: %{event: "message", data: []}

  defp post_raw(message, state) do
    with {:ok, body} <- Protocol.encode(message),
         {:ok, post_url} <- require_post_url(state) do
      headers = http_headers(state.config.headers)
      timeout = state.config.timeout_ms
      request = {to_charlist(post_url), headers, ~c"application/json", to_charlist(body)}
      http_opts = [timeout: timeout, connect_timeout: timeout]

      case :httpc.request(:post, request, http_opts, body_format: :binary) do
        {:ok, {{_version, status, _reason}, _headers, _response_body}} when status in 200..299 ->
          :ok

        {:ok, {{_version, status, reason}, _headers, response_body}} ->
          {:error, {:http_error, status, to_string(reason), to_string(response_body)}}

        {:error, reason} ->
          {:error, {:http_request_failed, reason}}
      end
    end
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

  defp resolve_endpoint(base_url, endpoint) do
    endpoint_uri = URI.parse(endpoint)

    if endpoint_uri.scheme in ["http", "https"] do
      endpoint
    else
      base_url
      |> URI.parse()
      |> URI.merge(endpoint)
      |> URI.to_string()
    end
  end

  defp trim_sse_value(" " <> value), do: value
  defp trim_sse_value(value), do: value

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp close_stream(%{stream_conn: conn}) when not is_nil(conn) do
    {:ok, _conn} = Mint.HTTP.close(conn)
    :ok
  end

  defp close_stream(_state), do: :ok

  defp ensure_http_apps do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp http_headers(headers) do
    Enum.map(headers, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)
  end
end
