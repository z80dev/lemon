defmodule LemonCore.Runtime.Health do
  @moduledoc """
  Health and readiness checks for the Lemon runtime.

  Provides functions to probe whether a Lemon runtime is already running on a
  given port and to report the current health of running applications.  This
  replaces the `curl -sS -m 2 http://localhost:$PORT/healthz` check that
  previously lived in `bin/lemon`.

  ## Usage

      # Check if another instance is already running
      LemonCore.Runtime.Health.running?(4040)
      # => true | false

      # Wait for startup
      {:ok, :healthy} = LemonCore.Runtime.Health.await(4040, timeout_ms: 10_000)

      # Report local readiness
      LemonCore.Runtime.Health.status()
      # => %{status: :ok, apps: [...], missing: []}
  """

  require Logger

  @default_timeout_ms 2_000
  @healthz_path "/healthz"
  @poll_interval_ms 500

  @doc """
  Returns `true` if a Lemon control-plane process is already healthy on `port`.

  Uses a plain TCP-level HTTP request to avoid depending on an HTTP client
  library at startup.  Times out after `timeout_ms` (default: 2 000 ms).

  ## Options

    * `:timeout_ms` - how long to wait in milliseconds (default: 2 000)
    * `:path` - health endpoint path (default: `"/healthz"`)
  """
  @spec running?(pos_integer(), keyword()) :: boolean()
  def running?(port, opts \\ []) when is_integer(port) and port > 0 do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    path = Keyword.get(opts, :path, @healthz_path)

    case probe(port, path, timeout) do
      {:ok, 200} -> true
      _ -> false
    end
  end

  @doc """
  Polls `port` until the health endpoint returns HTTP 200 or `timeout_ms`
  elapses.

  Returns `{:ok, :healthy}` on success or `{:error, :timeout}` on failure.
  """
  @spec await(pos_integer(), keyword()) :: {:ok, :healthy} | {:error, :timeout}
  def await(port, opts \\ []) when is_integer(port) and port > 0 do
    timeout = Keyword.get(opts, :timeout_ms, 30_000)
    path = Keyword.get(opts, :path, @healthz_path)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_await(port, path, deadline)
  end

  @doc """
  Returns the health status of the locally running Lemon apps.

  Checks that each expected app in `apps` is started.  If no `apps` list is
  provided, returns the status for all applications currently loaded.

  ## Return shape

      %{
        status: :ok | :degraded,
        apps: [:lemon_gateway, ...],
        missing: []
      }
  """
  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    expected = Keyword.get(opts, :apps, [])
    started = Application.started_applications() |> Enum.map(fn {app, _, _} -> app end)

    missing =
      case expected do
        [] -> []
        apps -> Enum.reject(apps, &(&1 in started))
      end

    overall =
      if missing == [] do
        :ok
      else
        :degraded
      end

    %{status: overall, apps: started, missing: missing}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Private helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp do_await(port, path, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout}
    else
      case probe(port, path, min(@poll_interval_ms, deadline - now)) do
        {:ok, 200} ->
          {:ok, :healthy}

        _ ->
          Process.sleep(@poll_interval_ms)
          do_await(port, path, deadline)
      end
    end
  end

  defp probe(port, path, timeout_ms) do
    host = ~c"127.0.0.1"
    request = "GET #{path} HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n"

    case :gen_tcp.connect(host, port, [:binary, active: false], timeout_ms) do
      {:ok, socket} ->
        result =
          try do
            with :ok <- :gen_tcp.send(socket, request),
                 {:ok, response} <- recv_response(socket, timeout_ms) do
              parse_status(response)
            else
              _ -> {:error, :unreachable}
            end
          rescue
            _ -> {:error, :unreachable}
          end

        :gen_tcp.close(socket)
        result

      _ ->
        {:error, :unreachable}
    end
  end

  defp recv_response(socket, timeout) do
    recv_response(socket, timeout, "")
  end

  defp recv_response(socket, timeout, acc) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} -> recv_response(socket, timeout, acc <> data)
      {:error, :closed} -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_status(<<"HTTP/", _version::binary-size(3), " ", code::binary-size(3), _rest::binary>>) do
    case Integer.parse(code) do
      {status, ""} -> {:ok, status}
      _ -> {:error, :bad_response}
    end
  end

  defp parse_status(_), do: {:error, :bad_response}
end
