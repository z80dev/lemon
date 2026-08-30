defmodule LemonBrowser.CuaDriverCLI do
  @moduledoc "A sanitized one-shot client for Lemon's private cua-driver daemon."

  alias LemonBrowser.CuaDriverDaemon

  @spec call(String.t(), map(), pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def call(tool, arguments, timeout_ms, opts \\ []) do
    with {:ok, %{driver: driver, socket: socket}} <- CuaDriverDaemon.ensure_started(opts),
         {:ok, output} <-
           run_command(
             driver,
             ["call", tool, Jason.encode!(arguments), "--socket", socket],
             timeout_ms
           ),
         {:ok, decoded} <- decode_output(output) do
      decoded = normalize_envelope(decoded)

      if decoded["isError"] == true do
        {:error, {:cua_driver_error, safe_driver_error(decoded)}}
      else
        {:ok, decoded}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in ErlangError -> {:error, {:cua_driver_call_failed, Exception.message(error)}}
  end

  defp normalize_envelope(decoded) do
    if Enum.any?(["content", "structuredContent", "data", "images"], &Map.has_key?(decoded, &1)) do
      decoded
    else
      %{
        "structuredContent" => decoded,
        "isError" => decoded["ok"] == false
      }
    end
  end

  defp decode_output(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      _ ->
        output
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.find_value(fn line ->
          case Jason.decode(line) do
            {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
            _ -> nil
          end
        end)
        |> case do
          nil -> {:error, {:invalid_cua_driver_response, safe_output(output)}}
          decoded -> decoded
        end
    end
  end

  defp run_command(driver, args, timeout_ms) do
    port =
      Port.open(
        {:spawn_executable, driver},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          args: args,
          env: port_env()
        ]
      )

    collect(port, timeout_ms, [])
  rescue
    error -> {:error, {:cua_driver_call_failed, Exception.message(error)}}
  end

  defp collect(port, timeout_ms, chunks) do
    receive do
      {^port, {:data, data}} ->
        collect(port, timeout_ms, [data | chunks])

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, status}} ->
        output = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        {:error, {:cua_driver_call_failed, status, safe_output(output)}}
    after
      timeout_ms ->
        Port.close(port)
        {:error, {:cua_driver_timeout_outcome_unknown, timeout_ms}}
    end
  end

  defp safe_driver_error(decoded) do
    structured = decoded["structuredContent"] || %{}
    structured["message"] || structured["code"] || "cua-driver rejected the request"
  end

  defp safe_output(output), do: output |> to_string() |> String.slice(0, 500)

  defp port_env do
    [
      {~c"CUA_DRIVER_RS_TELEMETRY_ENABLED", ~c"0"},
      {~c"ANTHROPIC_API_KEY", false},
      {~c"OPENAI_API_KEY", false},
      {~c"EXA_API_KEY", false},
      {~c"BRAVE_API_KEY", false},
      {~c"FIRECRAWL_API_KEY", false},
      {~c"BROWSERBASE_API_KEY", false},
      {~c"BROWSER_USE_API_KEY", false}
    ]
  end
end
