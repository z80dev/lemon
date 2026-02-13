defmodule LemonCore.Browser.LocalServer do
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

  alias LemonCore.Id

  @name __MODULE__

  @type result :: {:ok, term()} | {:error, String.t()}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @spec request(String.t(), map(), pos_integer()) :: result()
  def request(method, args \\ %{}, timeout_ms \\ 30_000)
      when is_binary(method) and is_map(args) do
    GenServer.call(@name, {:request, method, args, timeout_ms}, timeout_ms + 5_000)
  end

  @impl true
  def init(_opts) do
    {:ok,
     %{
       port: nil,
       buffer: "",
       pending: %{}
     }}
  end

  @impl true
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
        {:noreply, %{state | pending: pending}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
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
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp ensure_port(%{port: port} = state) when is_port(port), do: {:ok, state}

  defp ensure_port(state) do
    with {:ok, node_path} <- find_node(),
         {:ok, driver_path} <- find_driver() do
      args = [driver_path]

      port =
        Port.open({:spawn_executable, node_path}, [
          :binary,
          :exit_status,
          :hide,
          {:args, args}
        ])

      {:ok, %{state | port: port}}
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

  defp find_driver do
    override = System.get_env("LEMON_BROWSER_DRIVER_PATH") |> to_string_safe()

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
        end

        %{state | pending: pending}

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

    %{state | pending: %{}}
  end
end
