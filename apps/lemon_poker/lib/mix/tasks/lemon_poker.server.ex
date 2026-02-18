defmodule Mix.Tasks.LemonPoker.Server do
  @shortdoc "Run the poker spectator UI server"
  @moduledoc """
  Starts a local HTTP/WebSocket server for live poker matches and browser visualization.

  Examples:

      mix lemon_poker.server
      mix lemon_poker.server --port 4200 --host 0.0.0.0
  """

  use Mix.Task

  @switches [port: :integer, host: :string]

  @impl true
  def run(args) do
    LemonPoker.RuntimeConfig.apply_for_local_poker!()

    case Application.ensure_all_started(:lemon_poker) do
      {:ok, _apps} ->
        :ok

      {:error, {app, reason}} ->
        Mix.raise("Failed to start #{app}: #{inspect(reason)}")
    end

    LemonPoker.RuntimeConfig.assert_isolated_runtime!()

    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    port = Keyword.get(opts, :port, 4100)
    host = Keyword.get(opts, :host, "127.0.0.1")
    ip = parse_ip!(host)

    {:ok, _pid} =
      Bandit.start_link(
        plug: LemonPoker.Web.Router,
        scheme: :http,
        ip: ip,
        port: port
      )

    Mix.shell().info("Poker UI running at http://#{host}:#{port}")
    Mix.shell().info("Open in browser, then use the control panel to start a match.")

    Process.sleep(:infinity)
  end

  defp parse_ip!(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> ip
      {:error, _reason} -> Mix.raise("Invalid host IP address: #{host}")
    end
  end
end
