defmodule LemonCli.BrowserCommand do
  @moduledoc "Stops the running runtime's local browser driver through `browser.stop`."

  def run(args) do
    case OptionParser.parse(args, strict: [json: :boolean]) do
      {opts, ["stop"], []} -> stop(opts[:json] == true)
      _ -> usage()
    end
  end

  defp stop(json?) do
    client = Application.get_env(:lemon_cli, :control_plane_client, LemonCli.ControlPlaneClient)

    case client.request("browser.stop", %{}, timeout_ms: 30_000) do
      {:ok, result} ->
        if json?,
          do: IO.puts(Jason.encode!(result)),
          else: IO.puts("Local browser driver stopped.")

        0

      {:error, reason} ->
        failure(reason, json?)
    end
  end

  defp usage do
    IO.puts(:stderr, "Usage: lemon browser stop [--json]")
    2
  end

  defp failure(reason, json?) do
    {kind, message} = error_message(reason)

    if json?,
      do: IO.puts(:stderr, Jason.encode!(%{error: %{kind: kind, message: message}})),
      else: IO.puts(:stderr, "Error: #{message}")

    1
  end

  defp error_message({:control_plane_unavailable, _}),
    do:
      {"runtime_not_running",
       "Runtime not running or unreachable; no browser driver is running without it."}

  defp error_message(:control_plane_timeout),
    do:
      {"stop_timeout",
       "Browser stop timed out; whether the driver stopped is unknown. Check it before retrying."}

  defp error_message(_),
    do:
      {"stop_failed",
       "Runtime did not confirm the browser driver stopped; check operator authentication and runtime health."}
end
