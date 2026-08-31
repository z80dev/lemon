defmodule LemonBrowser.LocalServer do
  @moduledoc """
  Local browser driver backed by a Node + Playwright helper process.

  This is meant to provide "local browser mode" without requiring a paired node
  connection over the control plane.

  The helper is `clients/lemon-browser-node/dist/local-driver.js` and speaks a
  line-delimited JSON protocol over stdin/stdout:

    request:  {"id": "...", "method": "browser.navigate", "args": {...}, "timeoutMs": 30000}
    response: {"id": "...", "ok": true, "result": {...}}
  """

  use GenServer

  require Logger

  alias LemonCore.Env
  alias LemonCore.Id

  @name __MODULE__

  @type result :: {:ok, term()} | {:error, String.t()}
  @type server :: GenServer.server()

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)

    case name do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec stop(server()) :: :ok
  def stop(server \\ @name) do
    GenServer.stop(server, :normal, 1_000)
  catch
    :exit, _ -> :ok
  end

  @spec request(String.t(), map(), pos_integer()) :: result()
  def request(method, args \\ %{}, timeout_ms \\ 30_000)
      when is_binary(method) and is_map(args) do
    request(@name, method, args, timeout_ms)
  end

  @spec request(server(), String.t(), map(), pos_integer()) :: result()
  def request(server, method, args, timeout_ms)
      when is_binary(method) and is_map(args) do
    GenServer.call(server, {:request, method, args, timeout_ms}, timeout_ms + 5_000)
  end

  @spec status() :: map()
  def status, do: status(@name)

  @spec status(server()) :: map()
  def status(server) do
    GenServer.call(server, :status, 1_000)
  catch
    :exit, reason ->
      %{
        available: false,
        running: false,
        error: inspect(reason),
        pending_requests: 0
      }
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       port: nil,
       buffer: "",
       pending: %{},
       request_count: 0,
       completed_count: 0,
       failed_count: 0,
       started_at: nil,
       last_request_at: nil,
       last_error: nil,
       last_error_at: nil,
       driver_config: nil,
       driver_opts: Keyword.take(opts, [:cdp_endpoint, :attach_only, :driver_path])
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_from_state(state), state}
  end

  def handle_call({:request, method, args, timeout_ms}, from, state) do
    case ensure_port(state) do
      {:ok, state} ->
        id = Id.uuid()

        payload = %{
          "id" => id,
          "method" => method,
          "args" => args,
          "timeoutMs" => timeout_ms
        }

        line = Jason.encode!(payload) <> "\n"

        timer_ref = Process.send_after(self(), {:request_timeout, id}, timeout_ms)
        pending = Map.put(state.pending, id, {from, timer_ref})

        true = Port.command(state.port, line)

        {:noreply,
         %{
           state
           | pending: pending,
             request_count: state.request_count + 1,
             last_request_at: now_iso8601()
         }}

      {:error, reason} ->
        {:reply, {:error, reason}, remember_error(state, reason)}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    state = %{state | buffer: state.buffer <> data}
    {lines, buffer} = split_lines(state.buffer)
    state = %{state | buffer: buffer}

    state =
      Enum.reduce(lines, state, fn line, acc ->
        handle_line(line, acc)
      end)

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("Local browser driver exited (status=#{status})")
    state = fail_all_pending(state, "Local browser driver exited")
    {:noreply, %{state | port: nil, buffer: ""}}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, pending} ->
        {:noreply, %{state | pending: pending}}

      {{from, _timer_ref}, pending} ->
        GenServer.reply(from, {:error, "Browser request timed out"})

        {:noreply,
         state
         |> Map.merge(%{pending: pending, failed_count: state.failed_count + 1})
         |> remember_error("Browser request timed out")}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    close_port(port)
    :ok
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp close_port(port) when is_port(port) do
    if Port.info(port) do
      port
      |> port_info_value(:os_pid)
      |> signal_os_process()

      Port.close(port)
    end
  end

  defp signal_os_process(pid) when is_integer(pid) do
    _ =
      case System.find_executable("kill") do
        nil -> :ok
        _ -> System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
      end

    :ok
  catch
    _, _ -> :ok
  end

  defp signal_os_process(_pid), do: :ok

  defp ensure_port(%{port: port} = state) when is_port(port), do: {:ok, state}

  defp ensure_port(state) do
    with {:ok, node_path} <- find_node(),
         {:ok, driver_path} <- find_driver(state.driver_opts) do
      args = [driver_path | driver_args(state.driver_opts)]

      port =
        Port.open({:spawn_executable, node_path}, [
          :binary,
          :exit_status,
          :hide,
          {:args, args}
        ])

      {:ok,
       %{
         state
         | port: port,
           started_at: now_iso8601(),
           last_error: nil,
           last_error_at: nil,
           driver_config: driver_config_summary(state.driver_opts)
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_node do
    case System.find_executable("node") do
      nil -> {:error, "node executable not found on PATH"}
      path -> {:ok, path}
    end
  end

  defp find_driver(opts) do
    override =
      Keyword.get(opts, :driver_path) ||
        (Env.get(:lemon_browser_driver_path) |> to_string_safe())

    if override != "" do
      expanded = Path.expand(override)

      if File.exists?(expanded) do
        {:ok, expanded}
      else
        {:error, "LEMON_BROWSER_DRIVER_PATH does not exist: #{expanded}"}
      end
    else
      root = File.cwd!()
      candidate = Path.expand("clients/lemon-browser-node/dist/local-driver.js", root)

      if File.exists?(candidate) do
        {:ok, candidate}
      else
        {:error,
         "Local browser driver not built. Run: cd clients/lemon-browser-node && npm install && npm run build"}
      end
    end
  end

  defp to_string_safe(nil), do: ""
  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: to_string(value)

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n", trim: false)

    case Enum.split(parts, -1) do
      {lines, [last]} ->
        trimmed =
          lines
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {trimmed, last}

      _ ->
        {[], buffer}
    end
  end

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id} = msg} when is_binary(id) ->
        {entry, pending} = Map.pop(state.pending, id)

        if entry do
          {from, timer_ref} = entry
          _ = Process.cancel_timer(timer_ref)

          reply =
            case msg do
              %{"ok" => true, "result" => result} -> {:ok, result}
              %{"ok" => false, "error" => error} -> {:error, to_string(error)}
              _ -> {:error, "Malformed driver response"}
            end

          GenServer.reply(from, reply)

          state =
            case reply do
              {:ok, _} ->
                %{state | completed_count: state.completed_count + 1}

              {:error, reason} ->
                state
                |> Map.update!(:failed_count, &(&1 + 1))
                |> remember_error(reason)
            end

          %{state | pending: pending}
        else
          %{state | pending: pending}
        end

      {:ok, _} ->
        state

      {:error, _} ->
        state
    end
  end

  defp fail_all_pending(state, reason) do
    Enum.each(state.pending, fn {_id, {from, timer_ref}} ->
      _ = Process.cancel_timer(timer_ref)
      GenServer.reply(from, {:error, reason})
    end)

    state
    |> Map.merge(%{pending: %{}, failed_count: state.failed_count + map_size(state.pending)})
    |> remember_error(reason)
  end

  defp status_from_state(state) do
    port_info =
      if is_port(state.port) do
        %{
          os_pid: port_info_value(state.port, :os_pid),
          connected: inspect(port_info_value(state.port, :connected))
        }
      else
        nil
      end

    %{
      available: true,
      running: is_port(state.port),
      port: port_info,
      pending_requests: map_size(state.pending),
      buffer_bytes: byte_size(state.buffer),
      request_count: state.request_count,
      completed_count: state.completed_count,
      failed_count: state.failed_count,
      driver_config: state.driver_config || driver_config_summary(state.driver_opts),
      started_at: state.started_at,
      last_request_at: state.last_request_at,
      last_error: state.last_error,
      last_error_at: state.last_error_at
    }
  end

  defp port_info_value(port, key) do
    case Port.info(port, key) do
      {^key, value} -> value
      _ -> nil
    end
  end

  defp remember_error(state, reason) do
    %{state | last_error: to_string(reason), last_error_at: now_iso8601()}
  end

  defp driver_args(opts) do
    endpoint = configured_endpoint(opts)

    []
    |> maybe_append_arg(endpoint != "", "--cdp-endpoint", endpoint)
    |> maybe_append_flag(Keyword.get(opts, :attach_only, false) == true or endpoint != "", "--attach-only")
  end

  defp maybe_append_arg(args, true, flag, value), do: args ++ [flag, value]
  defp maybe_append_arg(args, false, _flag, _value), do: args
  defp maybe_append_flag(args, true, flag), do: args ++ [flag]
  defp maybe_append_flag(args, false, _flag), do: args

  defp configured_endpoint(opts) do
    case Keyword.get(opts, :cdp_endpoint) do
      value when is_binary(value) and value != "" -> value
      _ -> Env.get(:lemon_browser_cdp_endpoint) |> to_string_safe()
    end
  end

  defp driver_config_summary(opts) do
    endpoint = configured_endpoint(opts)

    attach_only? =
      Keyword.get(opts, :attach_only, false) == true or
        Env.get(:lemon_browser_attach_only) == true or endpoint != ""
    # Note: intentionally not `Env.get/2` -- LEMON_BROWSER_CDP_PORT only
    # accepts *positive* integers (0/negative fall back to the default),
    # which is stricter than the standard :integer cast's "any parseable
    # integer" behavior.
    cdp_port = Env.string("LEMON_BROWSER_CDP_PORT") |> parse_positive_int(18_800)

    %{
      mode: if(endpoint == "", do: "local_cdp", else: "remote_cdp"),
      launches_browser: endpoint == "" and not attach_only?,
      attach_only: attach_only?,
      cdp_port: if(endpoint == "", do: cdp_port, else: nil),
      cdp_endpoint_configured: endpoint != "",
      cdp_endpoint_hash: if(endpoint == "", do: nil, else: hash_value(endpoint))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp parse_positive_int(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> fallback
    end
  end

  defp parse_positive_int(_value, fallback), do: fallback

  defp hash_value(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end
end
