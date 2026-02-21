defmodule LemonServices.Runtime.HealthChecker do
  @moduledoc """
  Periodic health checker for services.

  Supports multiple health check types:
  - HTTP: GET request to a URL
  - TCP: Connect to a host:port
  - Command: Execute a shell command
  - Function: Call an Elixir function

  Reports health status to the Server process.
  """
  use GenServer

  alias LemonServices.Service.Definition

  require Logger

  @default_timeout_ms 5000

  # Client API

  def start_link(opts) do
    definition = Keyword.fetch!(opts, :definition)

    # Only start if health check is configured
    if definition.health_check do
      GenServer.start_link(__MODULE__, definition, name: via_tuple(definition.id))
    else
      :ignore
    end
  end

  @doc """
  Triggers an immediate health check.
  """
  @spec check_now(atom()) :: :ok | {:error, :not_running}
  def check_now(service_id) when is_atom(service_id) do
    case Registry.lookup(LemonServices.Registry, {:health_checker, service_id}) do
      [{pid, _}] ->
        GenServer.cast(pid, :check_now)
        :ok

      [] ->
        {:error, :not_running}
    end
  end

  # Server Callbacks

  @impl true
  def init(%Definition{} = definition) do
    # Get interval from health check config
    interval = get_interval(definition.health_check)

    # Schedule first check
    schedule_check(interval)

    {:ok, %{
      service_id: definition.id,
      health_check: definition.health_check,
      interval_ms: interval,
      last_status: :unknown,
      consecutive_failures: 0
    }}
  end

  @impl true
  def handle_cast(:check_now, state) do
    # Cancel pending timer and check immediately
    new_state = do_check(state)
    schedule_check(state.interval_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:check, state) do
    new_state = do_check(state)
    schedule_check(state.interval_ms)
    {:noreply, new_state}
  end

  # Private functions

  defp do_check(state) do
    case run_health_check(state.health_check) do
      :ok ->
        if state.last_status != :healthy do
          notify_server(state.service_id, :healthy)
        end

        %{state | last_status: :healthy, consecutive_failures: 0}

      {:error, reason} ->
        failures = state.consecutive_failures + 1

        # Only report unhealthy after 2 consecutive failures
        if failures >= 2 and state.last_status != :unhealthy do
          notify_server(state.service_id, :unhealthy, reason)
        end

        %{state | last_status: :unhealthy, consecutive_failures: failures}
    end
  end

  defp run_health_check({:http, url, _interval}) do
    # Simple HTTP GET check
    case :httpc.request(:get, {String.to_charlist(url), []}, [timeout: @default_timeout_ms], []) do
      {:ok, {{_, status, _}, _, _}} when status >= 200 and status < 400 ->
        :ok

      {:ok, {{_, status, _}, _, _}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp run_health_check({:tcp, host, port, _interval}) do
    # TCP connect check
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], @default_timeout_ms) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        {:error, "TCP connect failed: #{inspect(reason)}"}
    end
  end

  defp run_health_check({:command, cmd, _interval}) do
    # Shell command check (exit code 0 = healthy)
    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true, timeout: @default_timeout_ms) do
      {_, 0} ->
        :ok

      {output, code} ->
        {:error, "Command exited with code #{code}: #{output}"}
    end
  end

  defp run_health_check({:function, mod, fun, args, _interval}) do
    # Elixir function check
    try do
      case apply(mod, fun, args) do
        :ok -> :ok
        true -> :ok
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
        false -> {:error, "health check returned false"}
        other -> {:error, "unexpected return: #{inspect(other)}"}
      end
    rescue
      e ->
        {:error, "Exception: #{inspect(e)}"}
    end
  end

  defp notify_server(service_id, :healthy) do
    server_pid = get_server_pid(service_id)
    if server_pid, do: send(server_pid, {:health_check, :healthy})
  end

  defp notify_server(service_id, :unhealthy, reason) do
    server_pid = get_server_pid(service_id)
    if server_pid, do: send(server_pid, {:health_check, :unhealthy, reason})
  end

  defp get_server_pid(service_id) do
    case Registry.lookup(LemonServices.Registry, {:server, service_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp schedule_check(interval_ms) do
    Process.send_after(self(), :check, interval_ms)
  end

  defp get_interval({:http, _, interval}), do: interval
  defp get_interval({:tcp, _, _, interval}), do: interval
  defp get_interval({:command, _, interval}), do: interval
  defp get_interval({:function, _, _, _, interval}), do: interval

  defp via_tuple(service_id) do
    {:via, Registry, {LemonServices.Registry, {:health_checker, service_id}}}
  end
end
