defmodule LemonBrowser.Backends.Local do
  @moduledoc "Local Node/Playwright browser backend."

  @behaviour LemonBrowser.Backend

  alias LemonBrowser.LocalServer

  @impl true
  def id, do: :local

  @impl true
  def available?, do: true

  @impl true
  def request(method, args, timeout_ms, opts) do
    server = Keyword.get(opts, :server, LocalServer)
    LocalServer.request(server, method, args, timeout_ms)
  end

  @impl true
  def status(opts) do
    server = Keyword.get(opts, :server, LocalServer)
    LocalServer.status(server)
  end
end
