defmodule LemonCore.Tern do
  @moduledoc """
  Client for Tern's local daemon, with little-endian framed JSON and concurrent,
  deadline-bound requests. Socket discovery uses only this process's environment;
  callers cannot supply socket paths. Only sockets owned by the effective user
  are accepted. Unknown protocol members and unsolicited messages are ignored.
  """
  use GenServer
  import Bitwise

  @max_frame 256 * 1024 * 1024
  @kinds ~w(invalid not_found not_agent no_window window_closed unsupported js failed)a
  @safe_integer 9_007_199_254_740_991

  def connect(opts \\ []) do
    GenServer.start(__MODULE__, Keyword.put(Keyword.take(opts, [:timeout_ms]), :owner, self()))
  end

  def close(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  def supports?(pid, op), do: GenServer.call(pid, {:supports, op})

  def request(pid, channel, payload, timeout_ms \\ 30_000)
      when is_binary(channel) and is_map(payload) and is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(pid, {:request, channel, payload, timeout_ms}, :infinity)
  catch
    :exit, _ -> {:error, {:closed, "Tern connection closed"}}
  end

  def pane(value) when is_integer(value) and value >= 0 and value <= @safe_integer,
    do: {:ok, value}

  def pane(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9]+\z/, value) do
      case Integer.parse(value) do
        {integer, ""} -> pane(integer)
        _ -> {:error, :invalid_pane}
      end
    else
      {:error, :invalid_pane}
    end
  end

  def pane(_), do: {:error, :invalid_pane}
  def resolve_pane, do: pane(System.get_env("TERN_PANE"))
  @doc "Whether native browser integration is enabled for the invocation."
  def enabled?(opts \\ []) do
    config =
      Keyword.get(opts, :provider_config) ||
        Keyword.get_lazy(opts, :config, &LemonCore.Config.cached/0)

    browser = browser_config(config)
    LemonCore.Env.get(:lemon_browser_tern, default: value(browser, :tern) != false) == true
  end

  defp browser_config(config) when is_map(config) do
    cond do
      is_map(value(config, :browser)) -> value(config, :browser)
      is_map(value(config, :tools)) -> browser_config(value(config, :tools))
      is_map(value(config, :runtime)) -> browser_config(value(config, :runtime))
      is_map(value(config, :agent)) -> browser_config(value(config, :agent))
      true -> config
    end
  end

  defp browser_config(_), do: %{}
  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  @doc "Open a user-owned browser block beside the current CLI pane."
  def open_user_page(url) when is_binary(url) and url != "" do
    with {:ok, pane} <- resolve_pane(), {:ok, client} <- connect() do
      try do
        with true <- supports?(client, "browser"),
             {:ok, %{"block" => block}} <-
               request(
                 client,
                 "browser",
                 %{"op" => "open", "owner" => pane, "url" => url, "how" => "beside"},
                 15_000
               ) do
          case request(client, "browser", %{"op" => "release", "block" => block}, 5_000) do
            {:ok, _} ->
              :ok

            {:error, _} = error ->
              request(client, "browser", %{"op" => "close", "block" => block}, 5_000)
              error
          end
        else
          false -> {:error, {:unsupported, "Tern browser is unsupported"}}
          {:error, _} = error -> error
          _ -> {:error, {:protocol, "Invalid Tern browser reply"}}
        end
      after
        close(client)
      end
    end
  end

  def open_user_page(_), do: {:error, {:invalid, "Invalid URL"}}

  @doc "Resolve the daemon socket on this machine; never takes client input."
  def socket_path do
    System.get_env("TERN_PANE_SOCKET") || System.get_env("TERN_DAEMON_SOCKET") ||
      case System.get_env("TERN_CONFIG_DIR") do
        nil -> default_socket_path()
        dir -> Path.join(dir, "daemon.sock")
      end
  end

  defp default_socket_path do
    case :os.type() do
      {:unix, :darwin} ->
        Path.join([System.user_home!(), "Library", "Application Support", "Tern", "daemon.sock"])

      _ ->
        nil
    end
  end

  @impl true
  def init(opts) do
    timeout = Keyword.get(opts, :timeout_ms, 10_000)
    path = socket_path()
    deadline = System.monotonic_time(:millisecond) + timeout

    with :ok <- validate_socket(path),
         {:ok, socket} <-
           :gen_tcp.connect(
             {:local, String.to_charlist(path)},
             0,
             [:binary, active: false, send_timeout: timeout, send_timeout_close: true],
             timeout
           ) do
      with :ok <- send_frame(socket, %{"hello" => %{}}),
           {:ok, ops} <- welcome(socket, deadline),
           :ok <- :inet.setopts(socket, active: :once) do
        owner = Process.monitor(Keyword.fetch!(opts, :owner))

        {:ok,
         %{
           socket: socket,
           owner: owner,
           ops: ops,
           pending: %{},
           late_opens: MapSet.new(),
           next_id: 1,
           buffer: <<>>
         }}
      else
        {:error, reason} ->
          :gen_tcp.close(socket)
          {:stop, normalize_error(reason)}
      end
    else
      {:error, reason} -> {:stop, normalize_error(reason)}
    end
  end

  defp validate_socket(nil),
    do: {:error, {:connect, "Tern daemon socket is not configured on this platform"}}

  defp validate_socket(path) do
    with {:ok, stat} <- File.lstat(path),
         true <- (stat.mode &&& 0xF000) == 0xC000,
         {uid, 0} <- System.cmd("id", ["-u"]),
         true <- stat.uid == String.to_integer(String.trim(uid)) do
      :ok
    else
      _ -> {:error, {:connect, "Tern daemon socket is unavailable or not owned by this user"}}
    end
  end

  defp welcome(socket, deadline) do
    with {:ok, <<size::little-unsigned-32>>} <- recv(socket, 4, deadline),
         true <- size > 0 and size <= @max_frame,
         {:ok, body} <- recv(socket, size, deadline),
         {:ok, message} when is_map(message) <- Jason.decode(body) do
      case message do
        %{"welcome" => welcome} ->
          ops = if is_map(welcome), do: Map.get(welcome, "ops", []), else: []
          {:ok, if(is_list(ops), do: Enum.filter(ops, &is_binary/1), else: [])}

        _ ->
          welcome(socket, deadline)
      end
    else
      false -> {:error, {:protocol, "Invalid Tern frame length"}}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, {:protocol, "Invalid Tern welcome frame"}}
    end
  end

  defp recv(socket, size, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining > 0, do: :gen_tcp.recv(socket, size, remaining), else: {:error, :timeout}
  end

  @impl true
  def handle_call({:supports, op}, _from, state), do: {:reply, op in state.ops, state}

  def handle_call({:request, channel, payload, timeout}, from, state) do
    id = state.next_id
    started = System.monotonic_time(:millisecond)
    :inet.setopts(state.socket, send_timeout: timeout)

    case send_frame(state.socket, %{"id" => id, channel => payload}) do
      :ok ->
        remaining = max(timeout - (System.monotonic_time(:millisecond) - started), 0)
        timer = Process.send_after(self(), {:timeout, id}, remaining)

        pending =
          Map.put(
            state.pending,
            id,
            {from, channel, timer, channel == "browser" and payload["op"] == "open"}
          )

        {:noreply, %{state | pending: pending, next_id: id + 1}}

      {:error, reason} ->
        {:reply, {:error, normalize_error(reason)}, state}
    end
  end

  @impl true
  def handle_info({:tcp, socket, bytes}, %{socket: socket} = state) do
    case frames(%{state | buffer: state.buffer <> bytes}) do
      {:ok, state} ->
        :inet.setopts(socket, active: :once)
        {:noreply, state}

      {:error, reason, state} ->
        {:stop, :normal, fail_pending(state, reason)}
    end
  end

  def handle_info({:timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {{from, _, _, open?}, pending} ->
        GenServer.reply(from, {:error, {:timeout, "Tern request timed out"}})
        late_opens = if open?, do: MapSet.put(state.late_opens, id), else: state.late_opens
        {:noreply, %{state | pending: pending, late_opens: late_opens}}
    end
  end

  def handle_info({:DOWN, owner, :process, _, _}, %{owner: owner} = state),
    do: {:stop, :normal, fail_pending(state, {:closed, "Tern connection owner exited"})}

  def handle_info({event, socket}, %{socket: socket} = state)
      when event in [:tcp_closed, :tcp_error],
      do: {:stop, :normal, fail_pending(state, {:closed, "Tern connection closed"})}

  def handle_info({:tcp_error, socket, _}, %{socket: socket} = state),
    do: {:stop, :normal, fail_pending(state, {:closed, "Tern connection closed"})}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    fail_pending(state, {:closed, "Tern connection closed"})
    :gen_tcp.close(state.socket)
  end

  defp frames(%{buffer: buffer} = state) when byte_size(buffer) < 4, do: {:ok, state}

  defp frames(%{buffer: <<size::little-unsigned-32, rest::binary>>} = state) do
    cond do
      size == 0 or size > @max_frame ->
        {:error, {:protocol, "Invalid Tern frame length"}, state}

      byte_size(rest) < size ->
        {:ok, state}

      true ->
        <<body::binary-size(^size), remaining::binary>> = rest

        case Jason.decode(body) do
          {:ok, message} when is_map(message) ->
            case answer(message, %{state | buffer: remaining}) do
              {:ok, state} -> frames(state)
              error -> error
            end

          _ ->
            {:error, {:protocol, "Invalid Tern JSON object"}, state}
        end
    end
  end

  defp answer(%{"id" => id} = message, state) when is_integer(id) and id >= 0 do
    case Map.get(state.pending, id) do
      {from, channel, timer, _} ->
        case Map.fetch(message, channel) do
          {:ok, answer} ->
            Process.cancel_timer(timer)
            GenServer.reply(from, decode_answer(answer))
            {:ok, %{state | pending: Map.delete(state.pending, id)}}

          :error ->
            {:ok, state}
        end

      nil ->
        close_late_open(message, state)
    end
  end

  defp answer(message, state) when is_map_key(message, "browser") or is_map_key(message, "fork"),
    do: {:error, {:protocol, "Tern answer is missing a valid request id"}, state}

  defp answer(_, state), do: {:ok, state}

  defp close_late_open(%{"id" => id, "browser" => %{"ok" => %{"block" => block}}}, state) do
    if MapSet.member?(state.late_opens, id) do
      send_frame(state.socket, %{
        "id" => state.next_id,
        "browser" => %{"op" => "close", "block" => block}
      })

      {:ok,
       %{state | late_opens: MapSet.delete(state.late_opens, id), next_id: state.next_id + 1}}
    else
      {:ok, state}
    end
  end

  defp close_late_open(%{"id" => id, "browser" => _}, state),
    do: {:ok, %{state | late_opens: MapSet.delete(state.late_opens, id)}}

  defp close_late_open(_, state), do: {:ok, state}

  defp decode_answer(%{"ok" => result}), do: {:ok, result}

  defp decode_answer(%{"error" => %{"kind" => kind, "message" => message}})
       when is_binary(message) do
    atom = Enum.find(@kinds, :failed, &(Atom.to_string(&1) == kind))
    {:error, {atom, message}}
  end

  defp decode_answer(_), do: {:error, {:protocol, "Invalid Tern answer"}}

  defp fail_pending(state, reason) do
    Enum.each(state.pending, fn {_, {from, _, timer, _}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, reason})
    end)

    %{state | pending: %{}}
  end

  defp send_frame(socket, message) do
    body = Jason.encode!(message)

    if byte_size(body) <= @max_frame,
      do: :gen_tcp.send(socket, [<<byte_size(body)::little-unsigned-32>>, body]),
      else: {:error, {:protocol, "Tern request is too large"}}
  end

  defp normalize_error({kind, message}) when is_atom(kind) and is_binary(message),
    do: {kind, message}

  defp normalize_error(:timeout), do: {:timeout, "Tern connection timed out"}
  defp normalize_error(:closed), do: {:closed, "Tern connection closed"}
  defp normalize_error(_), do: {:connect, "Cannot connect to Tern daemon"}
end
