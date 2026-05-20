defmodule LemonMCP.Client.SSE do
  @moduledoc """
  MCP client GenServer for legacy HTTP+SSE MCP servers.

  This transport is kept for compatibility with older MCP servers. It opens the
  server-sent event stream, waits for the server `endpoint` event, sends
  JSON-RPC messages to that endpoint, and reads JSON-RPC responses from SSE
  `message` events.
  """

  use GenServer

  alias LemonMCP.Protocol

  @type client_state :: :disconnected | :initializing | :ready

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    gen_opts = Keyword.take(opts, [:name])
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
      timeout_ms: Keyword.get(opts, :timeout_ms, 30_000)
    }

    state = %{
      state: :initializing,
      config: config,
      stream_request_id: nil,
      post_url: nil,
      sse_buffer: "",
      sse_event: new_event(),
      server_info: nil,
      server_capabilities: nil
    }

    with :ok <- ensure_http_apps(),
         {:ok, state} <- open_stream(state),
         {:ok, state} <- await_endpoint(state),
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
  def handle_info({:http, {request_id, :stream_start, _headers}}, state)
      when request_id == state.stream_request_id do
    {:noreply, state}
  end

  @impl true
  def handle_info({:http, {request_id, :stream, chunk}}, state)
      when request_id == state.stream_request_id do
    {_events, state} = parse_sse_chunk(state, to_string(chunk))
    {:noreply, state}
  end

  @impl true
  def handle_info({:http, {request_id, :stream_end, _headers}}, state)
      when request_id == state.stream_request_id do
    {:noreply, %{state | state: :disconnected, stream_request_id: nil}}
  end

  @impl true
  def handle_info({:http, {request_id, {:error, _reason}}}, state)
      when request_id == state.stream_request_id do
    {:noreply, %{state | state: :disconnected, stream_request_id: nil}}
  end

  defp open_stream(state) do
    headers = [{~c"accept", ~c"text/event-stream"} | http_headers(state.config.headers)]
    request = {to_charlist(state.config.url), headers}
    timeout = state.config.timeout_ms
    http_opts = [timeout: timeout, connect_timeout: timeout]

    case :httpc.request(:get, request, http_opts,
           sync: false,
           stream: :self,
           body_format: :binary
         ) do
      {:ok, request_id} -> {:ok, %{state | stream_request_id: request_id}}
      {:error, reason} -> {:error, {:sse_stream_failed, reason}}
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
            true -> :cont
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
      {:http, {request_id, :stream_start, _headers}} when request_id == state.stream_request_id ->
        receive_sse_until(state, deadline, matcher)

      {:http, {request_id, :stream, chunk}} when request_id == state.stream_request_id ->
        {events, state} = parse_sse_chunk(state, to_string(chunk))
        match_events(events, state, deadline, matcher)

      {:http, {request_id, :stream_end, _headers}} when request_id == state.stream_request_id ->
        {:error, :sse_stream_closed, state}

      {:http, {request_id, {:error, reason}}} when request_id == state.stream_request_id ->
        {:error, {:sse_stream_failed, reason}, state}

      {:http, {request_id, result}} when request_id == state.stream_request_id ->
        {:error, {:unexpected_sse_message, result}, state}

      _other ->
        receive_sse_until(state, deadline, matcher)
    after
      timeout ->
        {:error, :timeout, state}
    end
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

  defp parse_sse_chunk(state, chunk) do
    combined = state.sse_buffer <> chunk
    lines = String.split(combined, "\n")

    {complete_lines, buffer} =
      if String.ends_with?(combined, "\n") do
        {lines, ""}
      else
        {Enum.drop(lines, -1), List.last(lines) || ""}
      end

    {events, event} =
      Enum.reduce(complete_lines, {[], state.sse_event}, fn line, {events, event} ->
        parse_sse_line(String.trim_trailing(line, "\r"), events, event)
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
  defp normalize_reply(other), do: {:error, {:unexpected_response, other}}

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

  defp close_stream(%{stream_request_id: request_id}) when not is_nil(request_id) do
    if function_exported?(:httpc, :cancel_request, 1) do
      :httpc.cancel_request(request_id)
    end

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
