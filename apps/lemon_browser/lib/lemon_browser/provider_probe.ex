defmodule LemonBrowser.ProviderProbe do
  @moduledoc "Read-only availability checks for the unified browser provider."

  alias LemonBrowser.{BackendRegistry, LocalServer}
  alias LemonCore.BrowserProvider.Command
  alias LemonCore.Env

  @timeout_ms 1_500

  def available?("relay") do
    with token when is_binary(token) and token != "" <- Env.get(:lemon_browser_relay_token),
         {:ok, %{status: 200, body: %{"extensionConnected" => true}}} <-
           Req.get("http://127.0.0.1:#{relay_port()}/health",
             headers: [{"authorization", "Bearer " <> token}],
             connect_options: [timeout: 500],
             receive_timeout: 500,
             retry: false,
             redirect: false
           ),
         {:ok, _} <- driver_available?() do
      {:ok, "Lemon MV3 relay extension is connected."}
    else
      nil ->
        {:error,
         "Set LEMON_BROWSER_RELAY_TOKEN and connect the Lemon MV3 extension to its relay."}

      "" ->
        {:error,
         "Set LEMON_BROWSER_RELAY_TOKEN and connect the Lemon MV3 extension to its relay."}

      _ ->
        {:error,
         "Lemon MV3 relay is unavailable or its extension is disconnected; start the relay and connect the extension."}
    end
  rescue
    _ ->
      {:error,
       "Lemon MV3 relay could not be checked; check its port, token and connected extension."}
  end

  # Local failures are fixed atoms, never helper output, so BrowserProvider can
  # name the missing prerequisite without exposing paths or probe details.
  def available?("local") do
    with :ok <- node_available(),
         {:ok, config} <- local_configuration(),
         {:ok, %{"available" => true}} <- inspect_browser(config) do
      {:ok, "Managed local Chrome and its CDP driver are available."}
    else
      {:ok, %{"reason" => "browser_executable_not_installed"}} -> {:error, :browser_missing}
      {:ok, %{}} -> {:error, :unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  def available?("cdp") do
    with :ok <- endpoint_configured("cdp"),
         {:ok, config} <- LocalServer.configuration(driver_options("cdp")),
         {:ok, %{"available" => true}} <- inspect_browser(config) do
      {:ok, "The configured CDP browser is reachable."}
    else
      {:error, :endpoint_missing} ->
        {:error,
         "Set LEMON_BROWSER_CDP_ENDPOINT to an existing reachable browser; cdp never launches a replacement."}

      _ ->
        {:error,
         "The configured CDP browser is unavailable; check LEMON_BROWSER_CDP_ENDPOINT and the browser driver installation."}
    end
  end

  def available?(provider) when provider in ["browserbase", "browser_use", "firecrawl"] do
    with {:ok, _} <- driver_available?(),
         {:ok, backend} <- BackendRegistry.fetch(provider),
         true <- backend.available?() do
      {:ok, "The hosted browser credentials and CDP driver are available."}
    else
      _ ->
        {:error,
         "Configure the hosted browser credentials and check the browser driver installation."}
    end
  end

  def available?(provider) do
    with {:ok, backend} <- BackendRegistry.fetch(provider),
         true <- backend.available?() do
      {:ok, "The configured #{provider} browser backend is available."}
    else
      _ ->
        {:error,
         "The #{provider} browser backend is unavailable; configure its existing credentials and backend settings."}
    end
  rescue
    _ -> {:error, "The configured browser backend could not be checked; review its settings."}
  catch
    :exit, _ ->
      {:error, "The configured browser backend is not running; start the required subsystem."}
  end

  @doc false
  def inspect_browser(config) do
    helper = Path.join(to_string(:code.priv_dir(:lemon_browser)), "node_browser_inspect.mjs")

    with {:ok, output} <-
           Command.run(["node", helper],
             input: Jason.encode!(config) <> "\n",
             timeout_ms: @timeout_ms,
             max_output_bytes: 65_536
           ),
         {:ok, result} <- Jason.decode(output) do
      case result do
        %{"error" => "driver_incompatible"} -> {:error, :driver_incompatible}
        %{"error" => _} -> {:error, :inspection_unavailable}
        result -> {:ok, result}
      end
    else
      _ -> {:error, :inspection_unavailable}
    end
  end

  defp node_available do
    if System.find_executable("node"), do: :ok, else: {:error, :node_missing}
  end

  # Node is checked first, so a configuration failure means the driver is absent.
  defp local_configuration do
    case LocalServer.configuration(driver_options("local")) do
      {:ok, config} -> {:ok, config}
      {:error, _} -> {:error, :driver_missing}
    end
  end

  @doc false
  def driver_options("local"), do: [cdp_endpoint: "", attach_only: false]

  def driver_options("relay") do
    token = Env.get(:lemon_browser_relay_token) || ""

    [
      cdp_endpoint: "ws://127.0.0.1:#{relay_port()}/cdp?token=#{URI.encode_www_form(token)}",
      attach_only: true
    ]
  end

  def driver_options("cdp"),
    do: [cdp_endpoint: Env.get(:lemon_browser_cdp_endpoint) || "", attach_only: true]

  defp driver_available?, do: LocalServer.configuration()

  defp endpoint_configured("cdp") do
    case Env.get(:lemon_browser_cdp_endpoint) do
      endpoint when is_binary(endpoint) and endpoint != "" -> :ok
      _ -> {:error, :endpoint_missing}
    end
  end

  defp relay_port do
    case Env.get(:lemon_browser_relay_port) do
      port when is_integer(port) and port > 0 and port <= 65_535 -> port
      _ -> 9224
    end
  end
end
