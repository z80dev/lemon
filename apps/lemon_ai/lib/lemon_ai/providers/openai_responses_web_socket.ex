defmodule LemonAi.Providers.OpenAIResponsesWebSocket do
  @moduledoc """
  Session-owned, opt-in transport for the OpenAI Responses WebSocket protocol.

  Start one transport with `start_link(owner: session_pid)` and pass its PID in
  `StreamOptions.provider_options.responses_transport`. `request/4` returns a
  single-use enumerable of decoded Responses events, consumed by the requesting
  process. Halting enumeration or losing that process closes the connection;
  it never retries an uncertain request.

  A successful response supplies an in-memory continuation anchor. Chaining
  requires the next input to contain the entire previous input and assistant
  output as a semantic prefix. Only a definite anchor rejection in the first
  data frame can cause one full replay. Three rejections disable chaining for
  this logical session, including across `reset/1` calls. Idle connections are
  actually closed after 30 seconds; resets also discard the connection/anchor.
  """

  use GenServer, restart: :temporary

  alias LemonAi.Providers.OpenAIResponsesShared
  alias __MODULE__.Connection

  @idle_timeout 30_000
  @max_rejections 3
  @terminal_types [
    "response.completed",
    "response.incomplete",
    "response.done",
    "response.failed",
    "error"
  ]

  defstruct [
    :owner,
    :owner_monitor,
    :socket,
    :identity,
    :baseline,
    :active,
    :idle_timer,
    :idle_token,
    connected: false,
    rejection_strikes: 0
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :owner))

  @spec request(pid(), String.t(), map() | list(), map()) ::
          {:ok, Enumerable.t()} | {:error, term(), nil}
  def request(pid, url, headers, body) do
    case call(pid, {:request, url, headers, body}) do
      {:ok, ref} -> {:ok, events(pid, ref, self())}
      {:error, reason} -> {:error, reason, nil}
    end
  end

  @doc "Closes the socket and forgets its anchor, but retains session rejection strikes."
  @spec reset(pid()) :: :ok | {:error, term()}
  def reset(pid), do: call(pid, :reset)

  @doc "Stops the transport and closes its socket."
  @spec close(pid()) :: :ok | {:error, term()}
  def close(pid), do: call(pid, :close)

  @impl true
  def init(owner) when is_pid(owner) do
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{owner: owner, owner_monitor: Process.monitor(owner)}}
  end

  @impl true
  def handle_call({:request, _url, _headers, _body}, _from, %{active: active} = state)
      when not is_nil(active) do
    {:reply, {:error, "Responses WebSocket already has an active request"}, state}
  end

  def handle_call({:request, url, headers, body}, {caller, _}, state) do
    with {:ok, url, headers} <- connection_options(url, headers),
         true <- is_map(body) and is_list(body["input"]) do
      body = Map.delete(body, "previous_response_id")
      identity = digest({url, headers, body["model"]})
      state = cancel_idle(state)
      state = if state.identity == identity, do: state, else: drop_connection(state)
      state = %{state | identity: identity}
      input = Enum.map(body["input"], &item_digest/1)
      {state, wire_body, chained} = continuation(state, body, input)

      case encode_request(wire_body) do
        {:ok, frame} ->
          ref = make_ref()

          active = %{
            ref: ref,
            caller: caller,
            monitor: Process.monitor(caller),
            input: input,
            outputs: %{},
            frame: frame,
            replay_body: if(chained, do: body),
            first_frame: true,
            chained: chained,
            terminal: false,
            completed: false,
            pending: nil,
            waiter: nil
          }

          case ensure_connection(%{state | active: active}, url, headers) do
            {:ok, state} ->
              {:reply, {:ok, ref}, send_request(state)}

            {:error, state} ->
              Process.demonitor(active.monitor, [:flush])
              {:reply, {:error, "Could not open Responses WebSocket"}, %{state | active: nil}}
          end

        {:error, _} ->
          {:reply, {:error, "Could not encode Responses WebSocket request"}, schedule_idle(state)}
      end
    else
      {:error, :insecure_url} ->
        {:reply, {:error, "Refusing plaintext Responses WebSocket to a non-loopback host"}, state}

      _ ->
        {:reply, {:error, "Invalid Responses WebSocket request"}, state}
    end
  end

  def handle_call({:next, ref}, {caller, _} = from, %{active: active} = state)
      when not is_nil(active) and active.ref == ref and active.caller == caller do
    case active.pending do
      {event, frame_from} ->
        acknowledge(frame_from)
        active = %{active | pending: nil}
        {:reply, {:event, event, active.terminal}, %{state | active: active}}

      nil when active.terminal ->
        {:reply, :halt, state}

      nil when is_nil(active.waiter) ->
        {:noreply, %{state | active: %{active | waiter: from}}}

      nil ->
        {:reply, {:error, "Responses WebSocket stream is already being consumed"}, state}
    end
  end

  def handle_call({:next, _ref}, _from, state) do
    {:reply, {:error, "Responses WebSocket request is no longer active"}, state}
  end

  def handle_call({:finish, ref}, {caller, _}, %{active: active} = state)
      when not is_nil(active) and active.ref == ref and active.caller == caller do
    state =
      if active.completed and is_nil(active.pending) do
        state |> clear_active() |> schedule_idle()
      else
        state |> drop_connection() |> clear_active()
      end

    {:reply, :ok, state}
  end

  def handle_call({:finish, _ref}, _from, state), do: {:reply, :ok, state}

  def handle_call({:frame, socket, event}, from, %{socket: socket, active: active} = state)
      when not is_nil(active) and not active.terminal do
    rejected = active.chained and definite_anchor_rejection?(event)

    state =
      if rejected, do: %{state | rejection_strikes: state.rejection_strikes + 1}, else: state

    if rejected and active.first_frame and not generation_evidence?(event) do
      # This rejection proves the chained request did not start generation. No
      # other failure, including a rejection after response.created, is replayed.
      replay_body = active.replay_body
      active = %{active | chained: false, first_frame: false, replay_body: nil}
      state = %{state | active: active, baseline: nil}

      case encode_request(replay_body) do
        {:ok, frame} ->
          WebSockex.cast(socket, {:request, frame})
          {:reply, :ok, state}

        {:error, _} ->
          state = fail_active(state, "Could not encode Responses WebSocket full replay")
          {:reply, :ok, drop_connection(state)}
      end
    else
      event = normalize_error(event)
      active = %{active | first_frame: false, replay_body: nil}
      active = remember_output(active, event)
      state = %{state | active: active}
      state = if event["type"] in @terminal_types, do: complete(state, event), else: state
      {:noreply, deliver(state, event, from)}
    end
  end

  def handle_call({:frame, _socket, _event}, _from, state), do: {:reply, :ok, state}

  def handle_call(:reset, _from, state) do
    state = fail_active(state, "Responses WebSocket request was reset")
    {:reply, :ok, %{drop_connection(state) | identity: nil}}
  end

  def handle_call(:close, _from, state) do
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({:connected, socket}, %{socket: socket} = state) do
    {:noreply, send_request(%{state | connected: true})}
  end

  def handle_info({:socket_error, socket, message}, %{socket: socket} = state) do
    {:noreply, state |> fail_active(message) |> drop_connection()}
  end

  def handle_info({:EXIT, socket, _reason}, %{socket: socket} = state) do
    state =
      fail_active(
        state,
        "Responses WebSocket closed before a terminal response (outcome unknown)"
      )

    {:noreply, drop_connection(state)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{owner_monitor: monitor} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{active: active} = state)
      when not is_nil(active) and active.monitor == monitor do
    {:noreply, state |> drop_connection() |> clear_active()}
  end

  def handle_info({:idle_expired, token}, %{idle_token: token, active: nil} = state)
      when not is_nil(token) do
    {:noreply, drop_connection(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    drop_connection(state)
    :ok
  end

  @impl true
  def format_status(status) do
    Map.put(status, :state, %{
      active: not is_nil(status.state.active),
      connected: status.state.connected
    })
  end

  defp events(pid, ref, caller) do
    Stream.resource(
      fn ->
        if self() != caller do
          throw(
            {:stream_error, "Responses WebSocket stream must be consumed by its request owner"}
          )
        end

        :streaming
      end,
      fn
        :done ->
          {:halt, :done}

        :streaming ->
          case call(pid, {:next, ref}) do
            {:event, event, terminal} -> {[event], if(terminal, do: :done, else: :streaming)}
            :halt -> {:halt, :done}
            {:error, reason} -> throw({:stream_error, reason})
          end
      end,
      fn _ -> call(pid, {:finish, ref}) end
    )
  end

  defp call(pid, message) do
    GenServer.call(pid, message, :infinity)
  catch
    :exit, _ -> {:error, "Responses WebSocket transport is unavailable (outcome unknown)"}
  end

  defp connection_options(url, headers) when is_binary(url) do
    uri = URI.parse(url)
    scheme = %{"https" => "wss", "http" => "ws", "wss" => "wss", "ws" => "ws"}[uri.scheme]

    if scheme && is_binary(uri.host) && uri.host != "" && is_nil(uri.userinfo) do
      headers =
        headers
        |> Enum.flat_map(fn {key, value} ->
          Enum.map(List.wrap(value), &{String.downcase(to_string(key)), to_string(&1)})
        end)
        |> Enum.sort()

      case plaintext_target(scheme, uri) do
        {:ok, uri} -> {:ok, URI.to_string(%{uri | scheme: scheme}), headers}
        error -> error
      end
    else
      {:error, :invalid_url}
    end
  rescue
    _ -> {:error, :invalid_connection_options}
  end

  defp connection_options(_url, _headers), do: {:error, :invalid_url}

  # Plaintext ws:// carries the bearer token unencrypted, so it is allowed only
  # to a literal loopback IP; bare `localhost` is pinned to 127.0.0.1 instead of
  # being resolved through DNS. Every other host requires wss://.
  defp plaintext_target("wss", uri), do: {:ok, uri}

  defp plaintext_target("ws", uri) do
    cond do
      literal_loopback?(uri.host) -> {:ok, uri}
      String.downcase(uri.host) == "localhost" -> {:ok, %{uri | host: "127.0.0.1"}}
      true -> {:error, :insecure_url}
    end
  end

  defp literal_loopback?(host) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      {:ok, {0, 0, 0, 0, 0, 0xFFFF, high, _}} -> div(high, 256) == 127
      _ -> false
    end
  end

  defp encode_request(body) do
    body
    |> Map.delete("stream")
    |> Map.put("type", "response.create")
    |> Jason.encode()
  end

  defp continuation(%{baseline: %{id: id, input: prefix}} = state, body, input) do
    if state.rejection_strikes < @max_rejections and prefix?(prefix, input) do
      body =
        body
        |> Map.put("previous_response_id", id)
        |> Map.put("input", Enum.drop(body["input"], length(prefix)))

      {state, body, true}
    else
      {drop_connection(state), body, false}
    end
  end

  defp continuation(state, body, _input), do: {state, body, false}

  defp prefix?([], _input), do: true
  defp prefix?([item | prefix], [item | input]), do: prefix?(prefix, input)
  defp prefix?(_prefix, _input), do: false

  defp ensure_connection(%{socket: socket} = state, _url, _headers) when is_pid(socket),
    do: {:ok, state}

  defp ensure_connection(state, url, headers) do
    case Connection.start_link(self(), url, headers) do
      {:ok, socket} -> {:ok, %{state | socket: socket, connected: false}}
      {:error, _reason} -> {:error, state}
    end
  end

  defp send_request(%{connected: true, active: %{frame: frame} = active} = state)
       when is_binary(frame) do
    WebSockex.cast(state.socket, {:request, frame})
    %{state | active: %{active | frame: nil}}
  end

  defp send_request(state), do: state

  defp deliver(%{active: %{waiter: nil} = active} = state, event, from) do
    # Hold the WebSockex call until the consumer asks for this event. There is
    # only one pending decoded frame, not an accumulating response/event queue.
    %{state | active: %{active | pending: {event, from}}}
  end

  defp deliver(%{active: active} = state, event, from) do
    GenServer.reply(active.waiter, {:event, event, active.terminal})
    acknowledge(from)
    %{state | active: %{active | waiter: nil}}
  end

  defp acknowledge(nil), do: :ok
  defp acknowledge(from), do: GenServer.reply(from, :ok)

  defp remember_output(active, %{
         "type" => "response.output_item.done",
         "output_index" => index,
         "item" => item
       })
       when is_integer(index) and index >= 0 and is_map(item) do
    %{active | outputs: Map.put(active.outputs, index, item_digest(item))}
  end

  defp remember_output(active, _event), do: active

  defp complete(state, event) do
    response = event["response"]

    completed =
      event["type"] in ["response.completed", "response.done"] and is_map(response) and
        response["status"] in [nil, "completed"]

    baseline =
      if completed and state.rejection_strikes < @max_rejections do
        case {response["id"], output_digests(response, state.active.outputs)} do
          {id, output} when is_binary(id) and id != "" and is_list(output) ->
            %{id: id, input: state.active.input ++ output}

          _ ->
            nil
        end
      end

    %{state | baseline: baseline, active: %{state.active | terminal: true, completed: completed}}
  end

  defp output_digests(%{"output" => output}, _items) when is_list(output),
    do: Enum.map(output, &item_digest/1)

  defp output_digests(_response, items) when map_size(items) > 0 do
    sorted = Enum.sort(items)

    if Enum.with_index(sorted)
       |> Enum.all?(fn {{index, _digest}, expected} -> index == expected end),
       do: Enum.map(sorted, &elem(&1, 1))
  end

  defp output_digests(_response, _items), do: nil

  defp fail_active(%{active: nil} = state, _message), do: state
  defp fail_active(%{active: %{terminal: true}} = state, _message), do: state

  defp fail_active(state, message) do
    case state.active.pending do
      {_event, from} -> acknowledge(from)
      nil -> :ok
    end

    active = %{
      state.active
      | pending: nil,
        terminal: true,
        completed: false,
        replay_body: nil,
        frame: nil
    }

    event = %{"type" => "error", "code" => "responses_websocket_transport", "message" => message}
    deliver(%{state | active: active, baseline: nil}, event, nil)
  end

  defp clear_active(%{active: nil} = state), do: state

  defp clear_active(state) do
    Process.demonitor(state.active.monitor, [:flush])
    %{state | active: nil}
  end

  defp drop_connection(state) do
    state = cancel_idle(state)

    if is_pid(state.socket) do
      # A close handshake can wait for the peer, and the socket may currently
      # be blocked on consumer demand. Killing its owning process closes the
      # actual socket immediately, including during cancellation and reset.
      Process.exit(state.socket, :kill)
    end

    %{state | socket: nil, connected: false, baseline: nil}
  end

  defp schedule_idle(%{socket: nil} = state), do: state

  defp schedule_idle(state) do
    token = make_ref()
    timer = Process.send_after(self(), {:idle_expired, token}, @idle_timeout)
    %{state | idle_timer: timer, idle_token: token}
  end

  defp cancel_idle(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: nil, idle_token: nil}
  end

  defp definite_anchor_rejection?(event) do
    response_error = if is_map(event["response"]), do: event["response"]["error"]
    error = event["error"] || response_error || event

    is_map(error) and event["type"] in ["error", "response.failed"] and
      (error["code"] in [
         "previous_response_not_found",
         "previous_response_id_not_found",
         "invalid_previous_response_id"
       ] or
         (error["param"] == "previous_response_id" and
            error["code"] in ["invalid_value", "invalid_request_error", "not_found"]))
  end

  defp generation_evidence?(event) do
    case event["response"] do
      nil ->
        false

      response when is_map(response) ->
        response["output"] not in [nil, []] or
          response["status"] in ["in_progress", "completed", "incomplete"] or
          match?(%{"output_tokens" => tokens} when tokens > 0, response["usage"])

      _ ->
        true
    end
  end

  defp normalize_error(%{"type" => "error"} = event) do
    error = if is_map(event["error"]), do: event["error"], else: event

    event
    |> Map.put("code", error["code"] || "responses_websocket_error")
    |> Map.put("message", error["message"] || "Responses WebSocket request failed")
  end

  defp normalize_error(%{"type" => type, "response" => %{"status" => status}} = event)
       when type in ["response.completed", "response.done"] and status in ["failed", "cancelled"] do
    Map.put(event, "type", "response.failed")
  end

  defp normalize_error(event), do: event

  # The shared converter recreates messages from text_signature, concatenates
  # text/refusal parts, drops annotations, and re-encodes tool argument maps.
  # Compare that semantic replay, not the raw response item's JSON bytes.
  defp item_digest(%{"type" => "message", "role" => "assistant", "content" => content} = item)
       when is_list(content) do
    text =
      Enum.map_join(content, "", fn
        %{"type" => "output_text", "text" => text} -> text
        %{"type" => "refusal", "refusal" => text} -> text
        _ -> ""
      end)

    id = item["id"]

    id =
      if is_binary(id) and String.length(id) > 64,
        do: "msg_" <> OpenAIResponsesShared.short_hash(id),
        else: id

    digest({:assistant, id, OpenAIResponsesShared.sanitize_surrogates(text)})
  end

  defp item_digest(%{"type" => "function_call", "arguments" => arguments} = item)
       when is_binary(arguments) do
    arguments =
      case Jason.decode(arguments) do
        {:ok, value} -> value
        _ -> {:invalid_json, arguments}
      end

    digest({:function_call, item["id"], item["call_id"], item["name"], arguments})
  end

  defp item_digest(%{"type" => "custom_tool_call"} = item) do
    digest({:custom_tool_call, item["id"], item["call_id"], item["name"], item["input"]})
  end

  # Reasoning signatures are replayed as the entire decoded item, including
  # encrypted_content and summary. Do not discard opaque signature fields.
  defp item_digest(item), do: digest(item)

  defp digest(value), do: :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))

  defmodule Connection do
    @moduledoc false
    use WebSockex

    def start_link(owner, url, headers) do
      opts = [
        async: true,
        handle_initial_conn_failure: true,
        extra_headers: headers
      ]

      opts =
        if String.starts_with?(url, "wss:") do
          Keyword.put(opts, :ssl_options,
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          )
        else
          opts
        end

      WebSockex.start_link(url, __MODULE__, %{owner: owner, socket: nil}, opts)
    end

    @impl true
    def handle_connect(conn, state) do
      # WebSockex defaults to active:true. Active-N also emits a passive notice,
      # allowing us to rearm only after all frames in this chunk were consumed.
      :ok = WebSockex.Conn.set_active(conn, 1)
      send(state.owner, {:connected, self()})
      socket_module = if conn.conn_mod == :gen_tcp, do: :inet, else: :ssl
      {:ok, %{state | socket: {socket_module, conn.socket}}}
    end

    @impl true
    def handle_cast({:request, frame}, state), do: {:reply, {:text, frame}, state}

    @impl true
    def handle_frame({:text, data}, state) do
      case Jason.decode(data) do
        {:ok, %{"type" => type} = event} when is_binary(type) ->
          GenServer.call(state.owner, {:frame, self(), event}, :infinity)
          {:ok, state}

        _ ->
          send(
            state.owner,
            {:socket_error, self(), "Responses WebSocket received an invalid JSON event"}
          )

          {:close, state}
      end
    catch
      :exit, _ -> Process.exit(self(), :kill)
    end

    def handle_frame(_frame, state) do
      send(
        state.owner,
        {:socket_error, self(), "Responses WebSocket received an unsupported data frame"}
      )

      {:close, state}
    end

    @impl true
    def handle_info({passive, socket}, %{socket: {mod, socket}} = state)
        when passive in [:tcp_passive, :ssl_passive] do
      :ok = mod.setopts(socket, active: 1)
      {:ok, state}
    end

    def handle_info(_message, state), do: {:ok, state}

    @impl true
    def handle_disconnect(status, state) do
      message =
        case status.reason do
          %WebSockex.RequestError{code: code} ->
            "Responses WebSocket handshake failed with HTTP #{code}"

          _ ->
            "Responses WebSocket disconnected before completion (outcome unknown)"
        end

      send(state.owner, {:socket_error, self(), message})
      {:ok, state}
    end

    @impl true
    def format_status(_reason, [_dictionary, _state]), do: :redacted
  end
end
