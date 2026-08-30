defmodule LemonBrowser.Backends.Camofox do
  @moduledoc "Camofox REST/Firefox browser backend."

  @behaviour LemonBrowser.Backend

  alias LemonBrowser.CamofoxSession

  @impl true
  def id, do: :camofox

  @impl true
  def available?, do: CamofoxSession.available?()

  @impl true
  def available?(opts), do: CamofoxSession.available?(opts)

  @impl true
  def request(method, args, timeout_ms, opts),
    do: CamofoxSession.request(method, args, timeout_ms, opts)

  @impl true
  def status(opts) do
    %{
      available: available?(opts),
      provider: "camofox",
      transport: "rest",
      sessions: CamofoxSession.status(),
      session_count: length(CamofoxSession.status())
    }
  end
end
