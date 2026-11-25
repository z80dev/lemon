defmodule LemonMCP.Client.HTTP do
  @moduledoc """
  MCP Client GenServer for Streamable HTTP MCP servers.

  This client performs the MCP initialize handshake over HTTP POST and then
  exposes the same public tool/resource/prompt API shape as `LemonMCP.Client`.
  It accepts both JSON and per-request server-sent event responses from current
  Streamable HTTP servers, and returns OAuth protected-resource and
  authorization-server metadata when a server requires authentication during
  startup.

  `:origin_policy` restricts every HTTP destination, including OAuth discovery
  and token exchanges. `:destination_pin` is a trusted, process-local option
  computed by the host before resolving credentials, never a server config field.
  Policy clients connect directly to the pinned address while retaining the
  original Host and TLS identity. All requests reject redirects. OAuth
  discovery, binding and grants are described in `LemonMCP.HTTP.OAuth`.

  ## Requests

  The handshake (including interactive OAuth) runs in `init/1`. After that the
  client process holds only the session id, protocol version, grant and server
  capabilities: every request runs in its own supervised worker and is
  answered with `GenServer.reply/2`, so `state/1` and concurrent requests never
  wait for a slow server. A request's deadline is the smaller of the caller's
  timeout and `:timeout_ms`. When it expires the worker is killed before the
  caller receives `{:error, :outcome_unknown}`: the request may have executed
  and is never replayed. A caller that exits also stops its request.

  A 401 on a request refreshes the grant once for all concurrent requests
  (refresh token or client credentials) and retries each 401'd request once.
  When only the interactive authorization-code flow could help, the request
  fails fast with the auth-required error and authorization runs in the
  background for later requests.
  """

  use GenServer

  require Logger

  alias LemonMCP.HTTP.{OAuth, OriginPolicy, Transport}
  alias LemonMCP.Protocol

  # Local margin for the worker's transport deadline so the client's own
  # deadline, which classifies the outcome, always fires first.
  @transport_margin_ms 1_000

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
  def list_tools(server, timeout \\ 30_000),
    do: request(server, :list_tools, Protocol.tool_list_request(), timeout)

  @spec call_tool(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, [Protocol.content_item()]} | {:error, term()}
  def call_tool(server, tool_name, arguments \\ %{}, timeout \\ 30_000) do
    request(
      server,
      :call_tool,
      Protocol.tool_call_request(name: tool_name, arguments: arguments),
      timeout
    )
  end

  @spec list_resources(GenServer.server(), timeout()) :: {:ok, [map()]} | {:error, term()}
  def list_resources(server, timeout \\ 30_000),
    do: request(server, :list_resources, Protocol.resource_list_request(), timeout)

  @spec read_resource(GenServer.server(), String.t(), timeout()) ::
          {:ok, [map()]} | {:error, term()}
  def read_resource(server, uri, timeout \\ 30_000),
    do: request(server, :read_resource, Protocol.resource_read_request(uri: uri), timeout)

  @spec list_prompts(GenServer.server(), timeout()) :: {:ok, [map()]} | {:error, term()}
  def list_prompts(server, timeout \\ 30_000),
    do: request(server, :list_prompts, Protocol.prompt_list_request(), timeout)

  @spec get_prompt(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def get_prompt(server, prompt_name, arguments \\ %{}, timeout \\ 30_000) do
    request(
      server,
      :get_prompt,
      Protocol.prompt_get_request(name: prompt_name, arguments: arguments),
      timeout
    )
  end

  @spec close(GenServer.server()) :: :ok
  def close(server), do: GenServer.call(server, :close)

  @spec server_info(GenServer.server()) :: {:ok, map()} | {:error, :not_connected}
  def server_info(server), do: GenServer.call(server, :server_info)

  @spec server_capabilities(GenServer.server()) :: {:ok, map()} | {:error, :not_connected}
  def server_capabilities(server), do: GenServer.call(server, :server_capabilities)

  # The client always answers at the request deadline, so the caller waits on
  # the reply (or the client's exit) rather than a second local timer.
  defp request(server, kind, request, timeout),
    do: GenServer.call(server, {:request, kind, request, timeout}, :infinity)

  @impl true
  def init(opts) do
    config = %{
      url: Keyword.fetch!(opts, :url),
      origin_policy: Keyword.get(opts, :origin_policy),
      destination_pin: nil,
      peer_owner:
        Keyword.get(opts, :peer_owner, &LemonCore.LoopbackListener.peer_owned_by_self?/2),
      headers: Keyword.get(opts, :headers, []),
      oauth: Keyword.get(opts, :oauth, []),
      oauth_token_cache: Keyword.get(opts, :oauth_token_cache) || OAuth.token_cache(opts),
      client_name: Keyword.get(opts, :client_name, "lemon-mcp"),
      client_version: Keyword.get(opts, :client_version, "0.1.0"),
      capabilities: Keyword.get(opts, :capabilities, %{}),
      notification_handler: Protocol.notification_handler(opts),
      timeout_ms: Keyword.get(opts, :timeout_ms, 30_000)
    }

    with :ok <- OAuth.validate_config(config.oauth),
         {:ok, pin} <-
           destination_pin(config.url, config.origin_policy, Keyword.get(opts, :destination_pin)),
         :ok <- Transport.ensure_started(),
         {:ok, task_supervisor} <- Protocol.start_notification_supervisor(opts) do
      state =
        %{
          state: :initializing,
          task_supervisor: task_supervisor,
          request_supervisor: nil,
          config: %{config | destination_pin: pin},
          server_info: nil,
          server_capabilities: nil,
          protocol_version: nil,
          session_id: nil,
          token_generation: 0,
          requests: %{},
          tasks: %{},
          auth: nil
        }
        |> Map.merge(OAuth.empty_tokens())
        |> OAuth.load_tokens()

      with {:ok, state} <- initialize(state),
           {:ok, state} <- send_initialized_notification(state),
           {:ok, request_supervisor} <- Task.Supervisor.start_link() do
        {:ok, %{state | state: :ready, request_supervisor: request_supervisor}}
      else
        {:error, reason} ->
          Protocol.stop_notification_supervisor(task_supervisor)
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    state = abort_all(state)
    Protocol.stop_notification_supervisor(state.task_supervisor)
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state.state, state}

  def handle_call({:request, kind, request, timeout}, {pid, _} = from, %{state: :ready} = state) do
    budget = min(timeout, state.config.timeout_ms)

    entry = %{
      kind: kind,
      request: request,
      from: from,
      caller_ref: Process.monitor(pid),
      deadline: System.monotonic_time(:millisecond) + budget,
      timer: Process.send_after(self(), {:request_deadline, request.id}, budget),
      task: nil,
      generation: state.token_generation,
      retried: false,
      metadata: nil
    }

    {:noreply, dispatch(state, entry)}
  end

  def handle_call({:request, _kind, _request, _timeout}, _from, state),
    do: {:reply, {:error, {:not_ready, state.state}}, state}

  def handle_call(:close, _from, state) do
    state = abort_all(state)
    Protocol.stop_notification_supervisor(state.task_supervisor)
    {:reply, :ok, %{state | state: :disconnected}}
  end

  def handle_call(:server_info, _from, %{state: :ready, server_info: info} = state),
    do: {:reply, {:ok, info}, state}

  def handle_call(:server_info, _from, state), do: {:reply, {:error, :not_connected}, state}

  def handle_call(:server_capabilities, _from, %{state: :ready} = state),
    do: {:reply, {:ok, state.server_capabilities || %{}}, state}

  def handle_call(:server_capabilities, _from, state),
    do: {:reply, {:error, :not_connected}, state}

  @impl true
  def handle_info({ref, result}, %{tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {id, tasks} = Map.pop(tasks, ref)
    state = %{state | tasks: tasks}
    entry = %{state.requests[id] | task: nil}
    {:noreply, request_result(state, id, entry, result)}
  end

  def handle_info({ref, result}, %{auth: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, auth_result(%{state | auth: nil}, state.auth, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    {id, tasks} = Map.pop(tasks, ref)
    {:noreply, finish(%{state | tasks: tasks}, id, {:error, :outcome_unknown})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{auth: %{ref: ref}} = state),
    do: {:noreply, auth_result(%{state | auth: nil}, state.auth, :error)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.requests, fn {_id, entry} -> entry.caller_ref == ref end) do
      {id, entry} -> {:noreply, drop(state, id, entry)}
      nil -> {:noreply, state}
    end
  end

  def handle_info({:request_deadline, id}, state) do
    case state.requests do
      %{^id => %{task: {_ref, _pid}} = entry} ->
        state = stop_task(state, entry)
        {:noreply, finish(state, id, {:error, :outcome_unknown})}

      %{^id => entry} ->
        {:noreply, finish(state, id, {:error, OAuth.required_reason(state, entry.metadata)})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ============================================================================
  # Request workers
  # ============================================================================

  defp dispatch(state, entry) do
    id = entry.request.id
    remaining = max(entry.deadline - System.monotonic_time(:millisecond), 1)
    ctx = worker_context(state, remaining + @transport_margin_ms)

    task =
      Task.Supervisor.async_nolink(state.request_supervisor, fn ->
        run_request(entry.kind, entry.request, ctx)
      end)

    entry = %{entry | task: {task.ref, task.pid}, generation: state.token_generation}

    %{
      state
      | requests: Map.put(state.requests, id, entry),
        tasks: Map.put(state.tasks, task.ref, id)
    }
  end

  defp worker_context(state, timeout_ms) do
    state
    |> Map.take([:config, :session_id, :protocol_version, :task_supervisor])
    |> Map.merge(OAuth.tokens(state))
    |> put_in([:config, :timeout_ms], timeout_ms)
  end

  defp run_request(kind, request, ctx) do
    case post(request, ctx) do
      {:ok, body, session_id} ->
        reply =
          with {:ok, response} <- decode_response_body(body, request.id),
               do: Protocol.result(kind, response)

        {:done, reply, session_id}

      {:unauthorized, metadata} ->
        {:unauthorized, metadata}

      {:error, reason} ->
        {:done, {:error, reason}, nil}
    end
  end

  defp request_result(state, id, entry, {:done, reply, session_id}) do
    state = put_session_id(state, session_id)
    finish(%{state | requests: Map.put(state.requests, id, entry)}, id, reply)
  end

  defp request_result(state, id, entry, {:unauthorized, {:error, reason}}),
    do: finish(%{state | requests: Map.put(state.requests, id, entry)}, id, {:error, reason})

  defp request_result(state, id, entry, {:unauthorized, {:ok, metadata}}) do
    entry = %{entry | metadata: metadata}
    state = %{state | requests: Map.put(state.requests, id, entry)}

    cond do
      entry.retried or not OAuth.configured?(state) ->
        finish(state, id, {:error, OAuth.required_reason(state, metadata)})

      # A grant arrived after this request was sent: retry with it once.
      entry.generation < state.token_generation ->
        dispatch(state, %{entry | retried: true})

      # Interactive authorization never runs on the request path.
      match?(%{interactive: true}, state.auth) ->
        finish(state, id, {:error, OAuth.required_reason(state, metadata)})

      # One refresh serves every request that saw the 401.
      is_nil(state.auth) ->
        start_auth(state, metadata, false)

      true ->
        state
    end
  end

  defp start_auth(state, metadata, interactive?) do
    ctx = Map.merge(Map.take(state, [:config]), OAuth.tokens(state))

    task =
      Task.Supervisor.async_nolink(state.request_supervisor, fn ->
        case OAuth.authorize(metadata, ctx, interactive?) do
          {:ok, ctx} -> {:ok, OAuth.tokens(ctx)}
          other -> other
        end
      end)

    %{
      state
      | auth: %{ref: task.ref, pid: task.pid, interactive: interactive?, metadata: metadata}
    }
  end

  defp auth_result(state, _auth, {:ok, tokens}) do
    state = %{Map.merge(state, tokens) | token_generation: state.token_generation + 1}

    Enum.reduce(parked(state), state, fn {_id, entry}, state ->
      dispatch(state, %{entry | retried: true})
    end)
  end

  defp auth_result(state, auth, :interactive_required) do
    state = fail_parked(state, fn entry -> OAuth.required_reason(state, entry.metadata) end)
    start_auth(state, auth.metadata, true)
  end

  defp auth_result(state, %{interactive: true}, _failed) do
    Logger.warning("MCP OAuth background authorization did not complete")
    state
  end

  defp auth_result(state, _auth, {:error, reason}), do: fail_parked(state, fn _ -> reason end)

  defp auth_result(state, _auth, _failed),
    do: fail_parked(state, fn entry -> OAuth.required_reason(state, entry.metadata) end)

  defp parked(state), do: Enum.filter(state.requests, fn {_id, entry} -> is_nil(entry.task) end)

  defp fail_parked(state, reason) do
    Enum.reduce(parked(state), state, fn {id, entry}, state ->
      finish(state, id, {:error, reason.(entry)})
    end)
  end

  defp finish(state, id, reply) do
    case Map.pop(state.requests, id) do
      {nil, _requests} ->
        state

      {entry, requests} ->
        _ = Process.cancel_timer(entry.timer)
        Process.demonitor(entry.caller_ref, [:flush])
        GenServer.reply(entry.from, reply)
        %{state | requests: requests}
    end
  end

  defp drop(state, id, entry) do
    state = stop_task(state, entry)
    _ = Process.cancel_timer(entry.timer)
    %{state | requests: Map.delete(state.requests, id)}
  end

  # The worker is killed before its caller is answered, so nothing it would
  # still send (a retry included) can run after the reply.
  defp stop_task(state, %{task: {ref, pid}}) do
    Process.exit(pid, :kill)
    Process.demonitor(ref, [:flush])
    %{state | tasks: Map.delete(state.tasks, ref)}
  end

  defp stop_task(state, _entry), do: state

  defp abort_all(%{requests: requests} = state) do
    state =
      Enum.reduce(requests, state, fn {id, entry}, state ->
        reply = if entry.task, do: :outcome_unknown, else: :connection_closed
        state |> stop_task(entry) |> finish(id, {:error, reply})
      end)

    case state.auth do
      %{ref: ref, pid: pid} ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        %{state | auth: nil}

      nil ->
        state
    end
  end

  defp abort_all(state), do: state

  defp put_session_id(state, nil), do: state
  defp put_session_id(state, session_id), do: %{state | session_id: session_id}

  # ============================================================================
  # Handshake (runs in init/1; interactive OAuth allowed)
  # ============================================================================

  defp initialize(state) do
    request =
      Protocol.initialize_request(
        client_name: state.config.client_name,
        client_version: state.config.client_version,
        capabilities: Protocol.client_capabilities(state.config.capabilities)
      )

    with {:ok, body, state} <- handshake_post(request, state, true),
         {:ok, response} <- decode_response_body(body, request.id),
         {:ok, result} <- Protocol.result(:initialize, response) do
      {:ok,
       %{
         state
         | server_info: result.serverInfo,
           server_capabilities: result.capabilities,
           protocol_version: result.protocolVersion
       }}
    end
  end

  defp send_initialized_notification(state) do
    case handshake_post(Protocol.initialized_notification(), state, true) do
      {:ok, _body, state} -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handshake_post(message, state, allow_oauth?) do
    case post(message, state) do
      {:ok, body, session_id} ->
        {:ok, body, put_session_id(state, session_id)}

      {:unauthorized, {:ok, metadata}} ->
        case allow_oauth? and OAuth.authorize(metadata, state, true) do
          {:ok, state} -> handshake_post(message, state, false)
          {:error, reason} -> {:error, reason}
          _ -> {:error, OAuth.required_reason(state, metadata)}
        end

      {:unauthorized, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # One HTTP exchange
  # ============================================================================

  # `ctx` is the client state or a worker snapshot of it. Returns the response
  # body (nil when empty) and any session id the server assigned.
  defp post(message, ctx) do
    with {:ok, body} <- Protocol.encode(message) do
      case Transport.request(
             :post,
             ctx.config.url,
             request_headers(ctx),
             {~c"application/json", to_charlist(body)},
             ctx.config,
             ctx.config.destination_pin
           ) do
        {:ok, {{_version, status, _reason}, headers, response_body}} when status in 200..299 ->
          session_id = session_id(headers)
          normalized_body = String.trim(to_string(response_body))
          content_type = Transport.response_header(headers, "content-type") || "application/json"

          case Jason.decode(normalized_body) do
            {:ok, message} ->
              Protocol.dispatch_notification(
                message,
                ctx.config.notification_handler,
                ctx.task_supervisor
              )

            _ ->
              :ok
          end

          cond do
            normalized_body in ["", "null"] ->
              {:ok, nil, session_id}

            String.contains?(content_type, "text/event-stream") ->
              with {:ok, data} <- decode_sse_response(normalized_body, ctx),
                   do: {:ok, data, session_id}

            true ->
              {:ok, normalized_body, session_id}
          end

        {:ok, {{_version, 401, reason}, headers, response_body}} ->
          {:unauthorized, OAuth.challenge_metadata(headers, reason, response_body, ctx)}

        {:ok, {{_version, status, reason}, _headers, response_body}} ->
          if is_nil(ctx.config.origin_policy),
            do: {:error, {:http_error, status, to_string(reason), to_string(response_body)}},
            else: {:error, :http_error}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp decode_response_body(nil, _id), do: {:error, :missing_response_body}

  defp decode_response_body(body, id) do
    with {:ok, decoded} <- Protocol.decode(body),
         true <- response_id(decoded) == id do
      case decoded do
        %{error: error} when not is_nil(error) -> {:error, {:rpc_error, error}}
        _ -> {:ok, decoded}
      end
    else
      false -> {:error, :response_id_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_sse_response(body, ctx) do
    events =
      body
      |> parse_sse_events()
      |> Enum.filter(&(&1.event == "message"))

    responses =
      Enum.reject(events, fn %{data: data} ->
        case Jason.decode(data) do
          {:ok, %{"method" => _} = message} when not is_map_key(message, "id") ->
            Protocol.dispatch_notification(
              message,
              ctx.config.notification_handler,
              ctx.task_supervisor
            )

            true

          _ ->
            false
        end
      end)

    case List.last(responses) do
      %{data: data} -> {:ok, data}
      nil -> {:error, :missing_sse_response}
    end
  end

  defp parse_sse_events(body) do
    body
    |> String.split("\n")
    |> LemonMCP.Client.SSE.Stream.parse_lines(LemonMCP.Client.SSE.Stream.new_event())
    |> LemonMCP.Client.SSE.Stream.finalize()
  end

  defp response_id(%{id: id}), do: id
  defp response_id(_), do: nil

  defp destination_pin(_url, nil, _pin), do: {:ok, nil}
  defp destination_pin(url, policy, nil), do: OriginPolicy.pin(url, policy)

  defp destination_pin(
         url,
         _policy,
         %{
           url: url,
           origin: origin,
           scheme: scheme,
           host: host,
           port: port,
           address: address
         } = pin
       )
       when scheme in ["http", "https"] do
    with {:ok, ^origin} <- OriginPolicy.canonical_origin(url),
         %URI{scheme: ^scheme, host: ^host, port: ^port} <- URI.parse(origin),
         rendered when is_list(rendered) <- :inet.ntoa(address) do
      {:ok, pin}
    else
      _ -> {:error, :invalid_destination_pin}
    end
  rescue
    _ -> {:error, :invalid_destination_pin}
  end

  defp destination_pin(_url, _policy, _pin), do: {:error, :invalid_destination_pin}

  defp request_headers(ctx) do
    base = [
      {"accept", "application/json, text/event-stream"},
      {"content-type", "application/json"}
    ]

    base =
      if ctx.protocol_version,
        do: [{"mcp-protocol-version", ctx.protocol_version} | base],
        else: base

    base = if ctx.session_id, do: [{"mcp-session-id", ctx.session_id} | base], else: base
    configured_headers = ctx.config.headers

    base =
      if OAuth.bearer_token?(ctx.oauth_access_token) and
           not has_header?(configured_headers, "authorization") do
        [{"authorization", "Bearer " <> ctx.oauth_access_token} | base]
      else
        base
      end

    Transport.headers(base ++ configured_headers)
  end

  defp has_header?(headers, name) do
    needle = String.downcase(name)

    Enum.any?(headers, fn
      {key, _value} -> key |> to_string() |> String.downcase() == needle
      _ -> false
    end)
  end

  defp session_id(headers) do
    case Transport.response_header(headers, "mcp-session-id") do
      "" -> nil
      session_id -> session_id
    end
  end
end
