defmodule LemonBrowser.CuaDriverDaemon do
  @moduledoc """
  Lazily owns one private `cua-driver` daemon for Lemon computer-use sessions.

  The daemon always runs in standard permission mode. Lemon's own tool policy is
  an additional gate; this process never selects cua-driver's unrestricted mode.
  """

  use GenServer

  @name __MODULE__
  @startup_timeout_ms 15_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)

  def ensure_started(opts \\ []) do
    GenServer.call(@name, {:ensure_started, opts}, @startup_timeout_ms + 2_000)
  end

  def status, do: GenServer.call(@name, :status)

  @impl true
  def init(_opts) do
    {:ok, %{port: nil, socket: nil, driver: nil, started_at: nil, last_error: nil}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       available: not is_nil(resolve_driver([])),
       running: is_port(state.port),
       started_at: state.started_at,
       last_error: state.last_error
     }, state}
  end

  def handle_call({:ensure_started, _opts}, _from, %{port: port} = state) when is_port(port) do
    {:reply, {:ok, %{driver: state.driver, socket: state.socket}}, state}
  end

  def handle_call({:ensure_started, opts}, _from, state) do
    case launch(opts) do
      {:ok, launched} ->
        next = Map.merge(state, launched) |> Map.put(:last_error, nil)
        {:reply, {:ok, Map.take(next, [:driver, :socket])}, next}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | last_error: safe_reason(reason)}}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:noreply, %{state | port: nil, last_error: "cua-driver daemon exited with status #{status}"}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.close(port)
    :ok
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp launch(opts) do
    with driver when is_binary(driver) <- resolve_driver(opts),
         socket <- socket_path(opts),
         :ok <- File.mkdir_p(Path.dirname(socket)),
         :ok <- remove_stale_socket(socket),
         port when is_port(port) <- open_daemon(driver, socket),
         :ok <- wait_ready(driver, socket, port, @startup_timeout_ms) do
      {:ok,
       %{
         port: port,
         driver: driver,
         socket: socket,
         started_at: DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    else
      nil -> {:error, {:cua_driver_unavailable, "cua-driver executable was not found"}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:cua_driver_start_failed, other}}
    end
  end

  defp open_daemon(driver, socket) do
    Port.open(
      {:spawn_executable, driver},
      [
        :binary,
        :exit_status,
        :hide,
        args: [
          "serve",
          "--socket",
          socket,
          "--permission-mode",
          "standard",
          "--no-overlay",
          "--embedded",
          "--host-bundle-id",
          "dev.z80.lemon"
        ],
        env: port_env()
      ]
    )
  rescue
    error -> {:error, {:cua_driver_start_failed, Exception.message(error)}}
  end

  defp wait_ready(_driver, _socket, port, _remaining) when not is_port(port),
    do: {:error, :cua_driver_port_closed}

  defp wait_ready(_driver, _socket, _port, remaining) when remaining <= 0,
    do: {:error, :cua_driver_start_timeout}

  defp wait_ready(driver, socket, port, remaining) do
    receive do
      {^port, {:exit_status, status}} ->
        {:error, {:cua_driver_exited_during_startup, status}}
    after
      0 ->
        case System.cmd(driver, ["status", "--socket", socket],
               stderr_to_stdout: true,
               env: cmd_env()
             ) do
          {output, 0} ->
            if String.contains?(String.downcase(output), "running") do
              :ok
            else
              Process.sleep(100)
              wait_ready(driver, socket, port, remaining - 100)
            end

          _ ->
            Process.sleep(100)
            wait_ready(driver, socket, port, remaining - 100)
        end
    end
  end

  defp resolve_driver(opts) do
    configured = Keyword.get(opts, :driver_path) || System.get_env("LEMON_CUA_DRIVER_CMD")

    cond do
      is_binary(configured) and File.exists?(configured) -> configured
      is_binary(configured) -> System.find_executable(configured)
      true -> System.find_executable("cua-driver")
    end
  end

  defp socket_path(opts) do
    Keyword.get(opts, :socket_path) ||
      Path.join(System.tmp_dir!(), "lemon-cua-#{System.pid()}.sock")
  end

  defp remove_stale_socket(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:cua_driver_socket_cleanup_failed, reason}}
    end
  end

  defp port_env do
    sensitive = [
      "ANTHROPIC_API_KEY",
      "OPENAI_API_KEY",
      "EXA_API_KEY",
      "BRAVE_API_KEY",
      "FIRECRAWL_API_KEY",
      "BROWSERBASE_API_KEY",
      "BROWSER_USE_API_KEY"
    ]

    [{~c"CUA_DRIVER_RS_TELEMETRY_ENABLED", ~c"0"}] ++
      Enum.map(sensitive, fn key -> {String.to_charlist(key), false} end)
  end

  defp cmd_env do
    [
      {"CUA_DRIVER_RS_TELEMETRY_ENABLED", "0"},
      {"ANTHROPIC_API_KEY", nil},
      {"OPENAI_API_KEY", nil},
      {"EXA_API_KEY", nil},
      {"BRAVE_API_KEY", nil},
      {"FIRECRAWL_API_KEY", nil},
      {"BROWSERBASE_API_KEY", nil},
      {"BROWSER_USE_API_KEY", nil}
    ]
  end

  defp safe_reason(reason), do: reason |> inspect(limit: 8) |> String.slice(0, 300)
end
