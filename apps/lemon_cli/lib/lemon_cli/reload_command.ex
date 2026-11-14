defmodule LemonCli.ReloadCommand do
  @moduledoc "Reloads compiled source changes in an already-running development runtime."

  def run(args) do
    case OptionParser.parse(args, strict: [sessions: :boolean, json: :boolean]) do
      {opts, [], []} ->
        client =
          Application.get_env(:lemon_cli, :control_plane_client, LemonCli.ControlPlaneClient)

        params = %{"sessions" => Keyword.get(opts, :sessions, true)}

        case client.request("system.reload_code", params, timeout_ms: 60_000) do
          {:ok, result} ->
            if opts[:json], do: IO.puts(Jason.encode!(result)), else: print_result(result)
            0

          {:error, reason} ->
            failure(reason, opts[:json] == true)
        end

      _ ->
        IO.puts(:stderr, "Usage: lemon reload [--no-sessions] [--json]")
        2
    end
  end

  defp print_result(result) do
    IO.puts(
      "Code: #{result["reloadedCount"]} reloaded, #{result["inUseCount"]} in use, " <>
        "#{result["failedCount"]} failed."
    )

    if sessions = result["sessions"] do
      IO.puts(
        "Sessions: #{sessions["refreshed"]} refreshed, #{sessions["busy"]} busy, " <>
          "#{sessions["failed"]} failed."
      )
    end

    Enum.each(result["failed"], fn failure ->
      IO.puts("Failed: #{clean(failure["module"])} (#{clean(failure["reason"])}).")
    end)

    if result["inUseCount"] > 0 do
      IO.puts(
        "Still in use: #{Enum.map_join(result["inUse"], ", ", &clean/1)}. Restart required."
      )
    end
  end

  defp failure(reason, json?) do
    {kind, message} = error_message(reason)

    if json? do
      IO.puts(:stderr, Jason.encode!(%{error: %{kind: kind, message: message}}))
    else
      IO.puts(:stderr, "Error: #{message}")
    end

    1
  end

  defp error_message({:control_plane_unavailable, _}),
    do:
      {"runtime_not_running",
       "Runtime not running or unreachable; start it with `lemon daemon` first."}

  defp error_message({:control_plane, _}),
    do:
      {"reload_refused",
       "Runtime refused code reload; use an authorized source-development runtime."}

  defp error_message(:control_plane_timeout),
    do:
      {"reload_timeout",
       "Code reload timed out; its outcome is unknown. Inspect the runtime before retrying."}

  defp error_message(_),
    do:
      {"reload_unavailable",
       "Code reload unavailable; check the running runtime and its operator credentials."}

  defp clean(value) do
    value
    |> to_string()
    |> LemonCore.Redact.text()
    |> String.replace(~r/[\x00-\x1f\x7f-\x9f]/u, " ")
  end
end
